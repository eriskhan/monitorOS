import Darwin
import Foundation
import MonitorOSCapture

private let monitorOSAudioPort = "5204"
private let monitorOSAudioMagic = Array("MOSAUD02".utf8)
private let monitorOSAudioLocalMagic = Array("MOSLOC02".utf8)
private let monitorOSAudioLocalVolumeMagic = Array("MOSVOL02".utf8)
private let monitorOSAudioLocalMuteMagic = Array("MOSMUT02".utf8)
private let monitorOSAudioSocketPath = "/tmp/monitoros-audio.sock"
private let monitorOSAudioLocalHeaderSize = 24
private let monitorOSAudioLocalControlSize = 12
private let monitorOSAudioNetworkHeaderSize = 40
private let monitorOSAudioSampleRate: UInt32 = 48_000
private let monitorOSAudioChannels: UInt16 = 2
private let monitorOSAudioFormatS16LE: UInt16 = 1

// Keep source PCM at unity. Speaker volume is owned by PipeWire/WirePlumber
// on the iMac and is controlled out-of-band through the monitorOS control
// plane, so PCM transport must never apply a second gain stage.
private let monitorOSAudioSafeGain: Float = 1.0

private struct MonitorOSAudioBlock {
    let ptsNanos: UInt64
    let frameCount: Int
    let pcm: [UInt8]
}

private enum MonitorOSAudioLocalMessage {
    case audio(MonitorOSAudioBlock)
    case volume(Float)
    case mute(Bool)
}

private struct MonitorOSAudioEndpoint: Equatable {
    let host: String
    let port: String

    init(videoTarget: String) throws {
        guard videoTarget.hasPrefix("["),
              let closingBracket = videoTarget.firstIndex(of: "]") else {
            throw MonitorOSCaptureError(
                "invalid speaker audio target derived from \(videoTarget)"
            )
        }
        host = String(
            videoTarget[
                videoTarget.index(after: videoTarget.startIndex)..<closingBracket
            ]
        )
        guard host.contains(":") else {
            throw MonitorOSCaptureError(
                "invalid speaker audio target derived from \(videoTarget)"
            )
        }
        port = monitorOSAudioPort
    }
}

final class MonitorOSAudioRelay: @unchecked Sendable {
    private let endpoint: MonitorOSAudioEndpoint
    private let controlSender: MonitorOSControlSender
    private let queue = DispatchQueue(
        label: "org.monitoros.helper.audio",
        qos: .userInteractive
    )
    private let stateLock = NSLock()
    private var localSocketFD: Int32 = -1
    private var networkSocketFD: Int32 = -1
    private var nextSequence: UInt64 = 0
    private var stopped = false

    init(videoTarget: String) throws {
        endpoint = try MonitorOSAudioEndpoint(videoTarget: videoTarget)
        controlSender = try MonitorOSControlSender(videoTarget: videoTarget)
        localSocketFD = try Self.makeLocalSocket()
        let localFD = localSocketFD
        queue.async { [weak self] in
            self?.receiveLoop(fd: localFD)
        }
        print(
            "monitorOS Helper: iMac Speakers relay ready on " +
            monitorOSAudioSocketPath
        )
    }

    deinit {
        stop()
    }

    func stop() {
        stateLock.lock()
        if stopped {
            stateLock.unlock()
            return
        }
        stopped = true
        let localFD = localSocketFD
        let networkFD = networkSocketFD
        localSocketFD = -1
        networkSocketFD = -1
        stateLock.unlock()

        if localFD >= 0 {
            Darwin.close(localFD)
        }
        if networkFD >= 0 {
            Darwin.close(networkFD)
        }
        monitorOSAudioSocketPath.withCString {
            _ = Darwin.unlink($0)
        }
    }

    private func receiveLoop(fd: Int32) {
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)

        while !isStopped {
            let received = buffer.withUnsafeMutableBytes { bytes -> Int in
                guard let base = bytes.baseAddress else {
                    return -1
                }
                return Darwin.recv(fd, base, bytes.count, 0)
            }

            if received < 0 {
                if errno == EINTR {
                    continue
                }
                if isStopped || errno == EBADF {
                    return
                }
                fputs(
                    "monitorOS Helper: speaker local recv failed: " +
                    String(cString: strerror(errno)) + "\n",
                    stderr
                )
                return
            }
            if received == 0 {
                continue
            }

            let packet = Array(buffer[..<received])
            do {
                switch try Self.decodeLocalMessage(packet) {
                case .audio(let block):
                    do {
                        try sendBlock(block)
                    } catch {
                        resetNetworkSocket()
                        fputs(
                            "monitorOS Helper: speaker audio relay dropped block: " +
                            "\(error)\n",
                            stderr
                        )
                    }
                case .volume(let scalar):
                    controlSender.setVolume(scalar)
                case .mute(let muted):
                    controlSender.setMute(muted)
                }
            } catch {
                fputs(
                    "monitorOS Helper: invalid local audio/control packet: " +
                    "\(error)\n",
                    stderr
                )
            }
        }
    }

    private var isStopped: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return stopped
    }

    private func sendBlock(_ block: MonitorOSAudioBlock) throws {
        let fd = try connectedSocket()

        stateLock.lock()
        let sequence = nextSequence
        stateLock.unlock()

        let header = Self.networkHeader(
            sequence: sequence,
            ptsNanos: block.ptsNanos,
            frameCount: block.frameCount
        )

        do {
            try Self.sendAll(
                fd: fd,
                bytes: header,
                label: "speaker block header"
            )
            try Self.sendAll(
                fd: fd,
                bytes: block.pcm,
                label: "speaker PCM"
            )

            stateLock.lock()
            if nextSequence == sequence {
                nextSequence &+= 1
            }
            stateLock.unlock()
        } catch {
            resetNetworkSocket(expectedFD: fd)
            throw error
        }
    }

    private func connectedSocket() throws -> Int32 {
        stateLock.lock()
        let existing = networkSocketFD
        let shouldStop = stopped
        stateLock.unlock()

        if shouldStop {
            throw MonitorOSCaptureError("speaker audio relay stopped")
        }
        if existing >= 0 {
            return existing
        }

        let fd = try connectSocket()
        do {
            try Self.configureAudioSocket(fd)
        } catch {
            Darwin.close(fd)
            throw error
        }

        stateLock.lock()
        if stopped {
            stateLock.unlock()
            Darwin.close(fd)
            throw MonitorOSCaptureError("speaker audio relay stopped")
        }
        if networkSocketFD < 0 {
            networkSocketFD = fd
            stateLock.unlock()
            print(
                "monitorOS Helper: iMac Speakers connected to " +
                "\(endpoint.host):\(endpoint.port)"
            )
            return fd
        }
        let selected = networkSocketFD
        stateLock.unlock()
        Darwin.close(fd)
        return selected
    }

    private func resetNetworkSocket(expectedFD: Int32? = nil) {
        stateLock.lock()
        let current = networkSocketFD
        if let expectedFD, current != expectedFD {
            stateLock.unlock()
            return
        }
        networkSocketFD = -1
        stateLock.unlock()

        if current >= 0 {
            Darwin.close(current)
        }
    }

    private func connectSocket() throws -> Int32 {
        var hints = addrinfo()
        hints.ai_family = AF_INET6
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP
        hints.ai_flags = AI_NUMERICSERV

        var addresses: UnsafeMutablePointer<addrinfo>?
        let result = endpoint.host.withCString { host in
            endpoint.port.withCString { port in
                getaddrinfo(host, port, &hints, &addresses)
            }
        }
        guard result == 0 else {
            throw MonitorOSCaptureError(
                "speaker resolve failed: " +
                String(cString: gai_strerror(result))
            )
        }
        defer {
            if let addresses {
                freeaddrinfo(addresses)
            }
        }

        var address = addresses
        var lastError: MonitorOSCaptureError?
        while let candidate = address {
            let info = candidate.pointee
            let fd = Darwin.socket(
                info.ai_family,
                info.ai_socktype,
                info.ai_protocol
            )
            if fd < 0 {
                lastError = MonitorOSCaptureError(
                    "speaker socket() failed: " +
                    String(cString: strerror(errno))
                )
                address = info.ai_next
                continue
            }

            do {
                var noSigPipe: Int32 = 1
                guard setsockopt(
                    fd,
                    SOL_SOCKET,
                    SO_NOSIGPIPE,
                    &noSigPipe,
                    socklen_t(MemoryLayout<Int32>.size)
                ) == 0 else {
                    throw MonitorOSCaptureError(
                        "speaker setsockopt(SO_NOSIGPIPE) failed"
                    )
                }

                guard let socketAddress = info.ai_addr else {
                    throw MonitorOSCaptureError(
                        "speaker target has no socket address"
                    )
                }

                let originalFlags = fcntl(fd, F_GETFL)
                guard originalFlags >= 0,
                      fcntl(fd, F_SETFL, originalFlags | O_NONBLOCK) == 0 else {
                    throw MonitorOSCaptureError(
                        "speaker fcntl(O_NONBLOCK) failed"
                    )
                }

                let connectResult = Darwin.connect(
                    fd,
                    socketAddress,
                    info.ai_addrlen
                )
                if connectResult != 0 {
                    guard errno == EINPROGRESS else {
                        throw MonitorOSCaptureError(
                            "speaker connect failed: " +
                            String(cString: strerror(errno))
                        )
                    }

                    var descriptor = pollfd(
                        fd: fd,
                        events: Int16(POLLOUT),
                        revents: 0
                    )
                    var pollResult: Int32
                    repeat {
                        pollResult = Darwin.poll(&descriptor, 1, 1_000)
                    } while pollResult < 0 && errno == EINTR

                    guard pollResult > 0 else {
                        throw MonitorOSCaptureError(
                            pollResult == 0
                                ? "speaker connect timed out after 1.0 s"
                                : "speaker connect poll failed: " +
                                    String(cString: strerror(errno))
                        )
                    }

                    var socketError: Int32 = 0
                    var socketErrorLength = socklen_t(
                        MemoryLayout<Int32>.size
                    )
                    guard getsockopt(
                        fd,
                        SOL_SOCKET,
                        SO_ERROR,
                        &socketError,
                        &socketErrorLength
                    ) == 0,
                    socketError == 0 else {
                        let code = socketError == 0 ? errno : socketError
                        throw MonitorOSCaptureError(
                            "speaker connect failed: " +
                            String(cString: strerror(code))
                        )
                    }
                }

                guard fcntl(fd, F_SETFL, originalFlags) == 0 else {
                    throw MonitorOSCaptureError(
                        "speaker failed to restore socket flags"
                    )
                }
                return fd
            } catch let error as MonitorOSCaptureError {
                lastError = error
                Darwin.close(fd)
            } catch {
                lastError = MonitorOSCaptureError(String(describing: error))
                Darwin.close(fd)
            }

            address = info.ai_next
        }

        throw lastError ?? MonitorOSCaptureError(
            "speaker target resolved to no usable addresses"
        )
    }

    private static func configureAudioSocket(_ fd: Int32) throws {
        var noDelay: Int32 = 1
        guard setsockopt(
            fd,
            IPPROTO_TCP,
            TCP_NODELAY,
            &noDelay,
            socklen_t(MemoryLayout<Int32>.size)
        ) == 0 else {
            throw MonitorOSCaptureError(
                "speaker setsockopt(TCP_NODELAY) failed"
            )
        }

        var timeout = timeval(tv_sec: 0, tv_usec: 100_000)
        guard setsockopt(
            fd,
            SOL_SOCKET,
            SO_SNDTIMEO,
            &timeout,
            socklen_t(MemoryLayout<timeval>.size)
        ) == 0 else {
            throw MonitorOSCaptureError(
                "speaker setsockopt(SO_SNDTIMEO) failed"
            )
        }
    }

    private static func makeLocalSocket() throws -> Int32 {
        let fd = Darwin.socket(AF_UNIX, SOCK_DGRAM, 0)
        guard fd >= 0 else {
            throw MonitorOSCaptureError(
                "speaker local socket() failed: " +
                String(cString: strerror(errno))
            )
        }

        do {
            var receiveBuffer: Int32 = 1 << 20
            guard setsockopt(
                fd,
                SOL_SOCKET,
                SO_RCVBUF,
                &receiveBuffer,
                socklen_t(MemoryLayout<Int32>.size)
            ) == 0 else {
                throw MonitorOSCaptureError(
                    "speaker local setsockopt(SO_RCVBUF) failed"
                )
            }

            monitorOSAudioSocketPath.withCString {
                _ = Darwin.unlink($0)
            }

            var address = sockaddr_un()
            address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
            address.sun_family = sa_family_t(AF_UNIX)
            let pathBytes = monitorOSAudioSocketPath.utf8CString
            let capacity = MemoryLayout.size(ofValue: address.sun_path)
            guard pathBytes.count <= capacity else {
                throw MonitorOSCaptureError(
                    "speaker local socket path is too long"
                )
            }

            withUnsafeMutablePointer(to: &address.sun_path) { pointer in
                pointer.withMemoryRebound(
                    to: CChar.self,
                    capacity: capacity
                ) { destination in
                    pathBytes.withUnsafeBufferPointer { source in
                        if let sourceBase = source.baseAddress {
                            memcpy(destination, sourceBase, pathBytes.count)
                        }
                    }
                }
            }

            let bindResult = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(
                    to: sockaddr.self,
                    capacity: 1
                ) { socketAddress in
                    Darwin.bind(
                        fd,
                        socketAddress,
                        socklen_t(MemoryLayout<sockaddr_un>.size)
                    )
                }
            }
            guard bindResult == 0 else {
                throw MonitorOSCaptureError(
                    "speaker local bind() failed: " +
                    String(cString: strerror(errno))
                )
            }
            let chmodResult = monitorOSAudioSocketPath.withCString {
                Darwin.chmod($0, 0o666)
            }
            guard chmodResult == 0 else {
                throw MonitorOSCaptureError(
                    "speaker local chmod() failed: " +
                    String(cString: strerror(errno))
                )
            }
            return fd
        } catch {
            Darwin.close(fd)
            monitorOSAudioSocketPath.withCString {
                _ = Darwin.unlink($0)
            }
            throw error
        }
    }

    private static func decodeLocalMessage(
        _ packet: [UInt8]
    ) throws -> MonitorOSAudioLocalMessage {
        guard packet.count >= 8 else {
            throw MonitorOSCaptureError(
                "local audio/control packet is too short"
            )
        }

        let magic = Array(packet[..<8])
        if magic == monitorOSAudioLocalMagic {
            return .audio(try decodeLocalPacket(packet))
        }

        if magic == monitorOSAudioLocalVolumeMagic {
            guard packet.count == monitorOSAudioLocalControlSize else {
                throw MonitorOSCaptureError(
                    "local speaker volume packet size mismatch"
                )
            }
            let bits = readUInt32LE(packet, offset: 8)
            let scalar = Float(bitPattern: bits)
            guard scalar.isFinite else {
                throw MonitorOSCaptureError(
                    "local speaker volume is not finite"
                )
            }
            return .volume(min(1, max(0, scalar)))
        }

        if magic == monitorOSAudioLocalMuteMagic {
            guard packet.count == monitorOSAudioLocalControlSize else {
                throw MonitorOSCaptureError(
                    "local speaker mute packet size mismatch"
                )
            }
            switch readUInt32LE(packet, offset: 8) {
            case 0:
                return .mute(false)
            case 1:
                return .mute(true)
            default:
                throw MonitorOSCaptureError(
                    "local speaker mute packet has invalid value"
                )
            }
        }

        throw MonitorOSCaptureError(
            "invalid local audio/control magic/version"
        )
    }

    private static func decodeLocalPacket(
        _ packet: [UInt8]
    ) throws -> MonitorOSAudioBlock {
        guard packet.count >= monitorOSAudioLocalHeaderSize,
              Array(packet[..<8]) == monitorOSAudioLocalMagic else {
            throw MonitorOSCaptureError(
                "invalid local speaker audio magic/version"
            )
        }

        let frameCount = Int(readUInt32LE(packet, offset: 8))
        guard frameCount > 0, frameCount <= 128 else {
            throw MonitorOSCaptureError(
                "invalid local speaker frame count \(frameCount)"
            )
        }

        let ptsNanos = readUInt64LE(packet, offset: 16)
        guard ptsNanos > 0 else {
            throw MonitorOSCaptureError(
                "invalid local speaker presentation timestamp"
            )
        }

        let sampleCount = frameCount * Int(monitorOSAudioChannels)
        let expected = monitorOSAudioLocalHeaderSize + sampleCount * 4
        guard packet.count == expected else {
            throw MonitorOSCaptureError(
                "local speaker packet size mismatch"
            )
        }

        var pcm = [UInt8](repeating: 0, count: sampleCount * 2)
        for sampleIndex in 0..<sampleCount {
            let offset = monitorOSAudioLocalHeaderSize + sampleIndex * 4
            let bits = readUInt32LE(packet, offset: offset)
            let sample = Float(bitPattern: bits)
            let finite = sample.isFinite ? sample : 0
            let clamped = min(1, max(-1, finite))
            let quantized = Int16(
                (clamped * monitorOSAudioSafeGain * 32_767).rounded()
            )
            let value = UInt16(bitPattern: quantized)
            pcm[sampleIndex * 2] = UInt8(truncatingIfNeeded: value)
            pcm[sampleIndex * 2 + 1] = UInt8(
                truncatingIfNeeded: value >> 8
            )
        }

        return MonitorOSAudioBlock(
            ptsNanos: ptsNanos,
            frameCount: frameCount,
            pcm: pcm
        )
    }

    private static func readUInt32LE(
        _ bytes: [UInt8],
        offset: Int
    ) -> UInt32 {
        UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }

    private static func readUInt64LE(
        _ bytes: [UInt8],
        offset: Int
    ) -> UInt64 {
        var value: UInt64 = 0
        for index in 0..<8 {
            value |= UInt64(bytes[offset + index]) << UInt64(index * 8)
        }
        return value
    }

    private static func appendUInt16BE(
        _ value: UInt16,
        to bytes: inout [UInt8]
    ) {
        bytes.append(UInt8(truncatingIfNeeded: value >> 8))
        bytes.append(UInt8(truncatingIfNeeded: value))
    }

    private static func appendUInt32BE(
        _ value: UInt32,
        to bytes: inout [UInt8]
    ) {
        bytes.append(UInt8(truncatingIfNeeded: value >> 24))
        bytes.append(UInt8(truncatingIfNeeded: value >> 16))
        bytes.append(UInt8(truncatingIfNeeded: value >> 8))
        bytes.append(UInt8(truncatingIfNeeded: value))
    }

    private static func appendUInt64BE(
        _ value: UInt64,
        to bytes: inout [UInt8]
    ) {
        for index in stride(from: 7, through: 0, by: -1) {
            bytes.append(
                UInt8(truncatingIfNeeded: value >> UInt64(index * 8))
            )
        }
    }

    private static func appendUInt32LE(
        _ value: UInt32,
        to bytes: inout [UInt8]
    ) {
        bytes.append(UInt8(truncatingIfNeeded: value))
        bytes.append(UInt8(truncatingIfNeeded: value >> 8))
        bytes.append(UInt8(truncatingIfNeeded: value >> 16))
        bytes.append(UInt8(truncatingIfNeeded: value >> 24))
    }

    private static func appendUInt64LE(
        _ value: UInt64,
        to bytes: inout [UInt8]
    ) {
        for index in 0..<8 {
            bytes.append(
                UInt8(truncatingIfNeeded: value >> UInt64(index * 8))
            )
        }
    }

    private static func networkHeader(
        sequence: UInt64,
        ptsNanos: UInt64,
        frameCount: Int
    ) -> [UInt8] {
        precondition(frameCount > 0 && frameCount <= Int(UInt32.max))

        var header = monitorOSAudioMagic
        appendUInt32BE(
            UInt32(monitorOSAudioNetworkHeaderSize),
            to: &header
        )
        appendUInt64BE(sequence, to: &header)
        appendUInt64BE(ptsNanos, to: &header)
        appendUInt32BE(UInt32(frameCount), to: &header)
        appendUInt32BE(monitorOSAudioSampleRate, to: &header)
        appendUInt16BE(monitorOSAudioChannels, to: &header)
        appendUInt16BE(monitorOSAudioFormatS16LE, to: &header)
        return header
    }

    private static func sendAll(
        fd: Int32,
        bytes: [UInt8],
        label: String
    ) throws {
        try bytes.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else {
                return
            }
            var offset = 0
            while offset < raw.count {
                let sent = Darwin.send(
                    fd,
                    base.advanced(by: offset),
                    raw.count - offset,
                    0
                )
                if sent < 0 {
                    if errno == EINTR {
                        continue
                    }
                    throw MonitorOSCaptureError(
                        "\(label) send() failed: " +
                        String(cString: strerror(errno))
                    )
                }
                if sent == 0 {
                    throw MonitorOSCaptureError(
                        "\(label) send() returned zero"
                    )
                }
                offset += sent
            }
        }
    }

    static func selfTest() -> Bool {
        do {
            let ipv6 = try MonitorOSAudioEndpoint(
                videoTarget: "[fe80::1234%bridge0]:5202"
            )
            guard ipv6.host == "fe80::1234%bridge0",
                  ipv6.port == "5204" else {
                return false
            }

            var packet = monitorOSAudioLocalMagic
            appendUInt32LE(1, to: &packet)
            appendUInt32LE(0, to: &packet)
            appendUInt64LE(123_456_789, to: &packet)
            appendUInt32LE(Float(1).bitPattern, to: &packet)
            appendUInt32LE(Float(-1).bitPattern, to: &packet)

            guard case .audio(let block) = try decodeLocalMessage(packet) else {
                return false
            }
            let header = networkHeader(
                sequence: 7,
                ptsNanos: block.ptsNanos,
                frameCount: block.frameCount
            )
            guard block.ptsNanos == 123_456_789,
                  block.frameCount == 1,
                  block.pcm == [0x00, 0x20, 0x00, 0xe0],
                  header.count == monitorOSAudioNetworkHeaderSize,
                  Array(header[..<8]) == monitorOSAudioMagic else {
                return false
            }

            var volumePacket = monitorOSAudioLocalVolumeMagic
            appendUInt32LE(Float(0.6).bitPattern, to: &volumePacket)
            guard case .volume(let volume) =
                    try decodeLocalMessage(volumePacket),
                  abs(volume - 0.6) < 0.0001 else {
                return false
            }

            var mutePacket = monitorOSAudioLocalMuteMagic
            appendUInt32LE(1, to: &mutePacket)
            guard case .mute(true) = try decodeLocalMessage(mutePacket) else {
                return false
            }
        } catch {
            return false
        }
        return true
    }
}

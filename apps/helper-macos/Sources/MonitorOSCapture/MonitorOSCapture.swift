import CoreGraphics
import CoreMedia
import CoreVideo
import Darwin
import Foundation
import ScreenCaptureKit
import CGVirtualDisplayPrivate

public struct MonitorOSCaptureError: Error, CustomStringConvertible, Sendable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var description: String {
        message
    }
}

public struct MonitorOSVirtualDisplayConfiguration: Sendable {
    public var name: String
    public var logicalWidth: Int
    public var logicalHeight: Int
    public var refreshRate: Double
    public var pixelsPerInch: Double
    public var vendorID: UInt32
    public var productID: UInt32
    public var serialNumber: UInt32

    public init(
        name: String,
        logicalWidth: Int = 2560,
        logicalHeight: Int = 1440,
        refreshRate: Double = 60,
        pixelsPerInch: Double = 220,
        vendorID: UInt32 = 0x4D4F,
        productID: UInt32 = 0x5A60,
        serialNumber: UInt32
    ) {
        self.name = name
        self.logicalWidth = logicalWidth
        self.logicalHeight = logicalHeight
        self.refreshRate = refreshRate
        self.pixelsPerInch = pixelsPerInch
        self.vendorID = vendorID
        self.productID = productID
        self.serialNumber = serialNumber
    }

    public var physicalWidth: Int {
        logicalWidth * 2
    }

    public var physicalHeight: Int {
        logicalHeight * 2
    }

    // BetterDisplay's raw CGVirtualDisplaySettings mode list, captured in
    // LLDB on macOS 27: 1280x720 through 7552x4248 in 64x36 steps, followed
    // by the 7680x4320 ceiling. These are raw pixel modes; WindowServer
    // synthesizes the corresponding HiDPI logical modes from them.
    var flexibleScalingBackingSizes: [(width: Int, height: Int)] {
        var sizes = stride(
            from: 1280,
            through: 7552,
            by: 64
        ).map { width in
            (
                width: width,
                height: width * logicalHeight / logicalWidth
            )
        }
        sizes.append((width: 7680, height: 4320))
        return sizes
    }

    var maximumBackingWidth: Int {
        flexibleScalingBackingSizes.last?.width ?? physicalWidth
    }

    var maximumBackingHeight: Int {
        flexibleScalingBackingSizes.last?.height ?? physicalHeight
    }
}

@MainActor
public final class MonitorOSVirtualDisplay {
    private let display: CGVirtualDisplay
    private let configuration: MonitorOSVirtualDisplayConfiguration

    public let displayID: CGDirectDisplayID

    public init(configuration: MonitorOSVirtualDisplayConfiguration) throws {
        self.configuration = configuration

        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.setDispatchQueue(.main)
        descriptor.name = configuration.name
        // Match BetterDisplay exactly: its descriptor ceiling is 7680x4320.
        // The pretty picker disappears if this ceiling is reduced to 5K.
        descriptor.maxPixelsWide = UInt32(configuration.maximumBackingWidth)
        descriptor.maxPixelsHigh = UInt32(configuration.maximumBackingHeight)
        descriptor.sizeInMillimeters = CGSize(
            width: Double(configuration.physicalWidth) * 25.4 / configuration.pixelsPerInch,
            height: Double(configuration.physicalHeight) * 25.4 / configuration.pixelsPerInch
        )
        descriptor.vendorID = configuration.vendorID
        descriptor.productID = configuration.productID
        descriptor.serialNum = configuration.serialNumber
        descriptor.terminationHandler = { _, _ in
            fputs("monitorOS virtual display terminated by WindowServer\n", stderr)
        }

        display = CGVirtualDisplay(descriptor: descriptor)

        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = 1

        // Match BetterDisplay's raw mode ordering as captured in LLDB.
        // Crucially, the list is ascending from 1280x720; BetterDisplay does
        // not put 5120x2880 first.
        let backingSizes = configuration.flexibleScalingBackingSizes

        settings.modes = backingSizes.map { size in
            CGVirtualDisplayMode(
                width: UInt(size.width),
                height: UInt(size.height),
                refreshRate: configuration.refreshRate
            )
        }

        fputs(
            "monitorOS virtual display flexible scaling: " +
            "rawModes=\(backingSizes.count) " +
            "range=\(backingSizes.first!.width)x" +
            "\(backingSizes.first!.height)-" +
            "\(backingSizes.last!.width)x" +
            "\(backingSizes.last!.height) " +
            "defaultTarget=\(configuration.logicalWidth)x" +
            "\(configuration.logicalHeight)@2x\n",
            stderr
        )

        guard display.apply(settings) else {
            throw MonitorOSCaptureError("CGVirtualDisplay.apply failed")
        }

        displayID = display.displayID
    }

    public func waitUntilReady(
        requireConfiguredLogicalSize: Bool = true
    ) async throws {
        for _ in 0..<50 {
            let online = CGDisplayIsOnline(displayID) == 1
            let active = CGDisplayIsActive(displayID) == 1
            let bounds = CGDisplayBounds(displayID)
            let logicalSizeReady =
                !requireConfiguredLogicalSize
                || (
                    Int(bounds.width.rounded()) == configuration.logicalWidth
                    && Int(bounds.height.rounded()) == configuration.logicalHeight
                )

            if online, active, logicalSizeReady {
                return
            }

            try await Task.sleep(for: .milliseconds(100))
        }

        let online = CGDisplayIsOnline(displayID) == 1
        let active = CGDisplayIsActive(displayID) == 1
        let bounds = CGDisplayBounds(displayID)

        if requireConfiguredLogicalSize {
            throw MonitorOSCaptureError(
                "virtual display did not settle at " +
                "\(configuration.logicalWidth)x\(configuration.logicalHeight) logical " +
                "(online=\(online) active=\(active) bounds=\(bounds))"
            )
        }

        throw MonitorOSCaptureError(
            "virtual display did not become ready " +
            "(online=\(online) active=\(active) bounds=\(bounds))"
        )
    }
}

public func monitorOSFindScreenCaptureDisplay(
    displayID: CGDirectDisplayID
) async throws -> SCDisplay {
    var lastDisplays: [SCDisplay] = []

    for _ in 0..<50 {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: false
        )
        lastDisplays = content.displays

        if let display = content.displays.first(where: { $0.displayID == displayID }) {
            return display
        }

        try await Task.sleep(for: .milliseconds(100))
    }

    let visible = lastDisplays.map {
        "id=\($0.displayID) \($0.width)x\($0.height)"
    }.joined(separator: ", ")

    throw MonitorOSCaptureError(
        "virtual display \(displayID) never appeared in ScreenCaptureKit; " +
        "visible displays: [\(visible)]"
    )
}

public func monitorOSFrameStatus(_ sampleBuffer: CMSampleBuffer) -> SCFrameStatus {
    guard
        let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false
        ) as? [[SCStreamFrameInfo: Any]],
        let attachments = attachmentsArray.first,
        let rawValue = attachments[.status] as? Int,
        let status = SCFrameStatus(rawValue: rawValue)
    else {
        return .complete
    }

    return status
}


public func monitorOSFrameDirtyRects(
    _ sampleBuffer: CMSampleBuffer
) -> [CGRect]? {
    guard
        let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false
        ) as? [[SCStreamFrameInfo: Any]],
        let attachments = attachmentsArray.first,
        let rawRects = attachments[.dirtyRects] as? NSArray
    else {
        return nil
    }

    var rects: [CGRect] = []
    rects.reserveCapacity(rawRects.count)

    for element in rawRects {
        if let value = element as? NSValue {
            rects.append(value.rectValue)
            continue
        }

        guard let dictionary = element as? NSDictionary,
              let x = dictionary.object(forKey: "X") as? NSNumber,
              let y = dictionary.object(forKey: "Y") as? NSNumber,
              let width = dictionary.object(forKey: "Width") as? NSNumber,
              let height = dictionary.object(forKey: "Height") as? NSNumber
        else {
            return nil
        }

        rects.append(
            CGRect(
                x: CGFloat(x.doubleValue),
                y: CGFloat(y.doubleValue),
                width: CGFloat(width.doubleValue),
                height: CGFloat(height.doubleValue)
            )
        )
    }

    return rects
}

struct MonitorOSDamageRegion: Equatable, Sendable {
    let x: Int
    let y: Int
    let width: Int
    let height: Int

    var pixelCount: Int {
        width * height
    }

}

private let monitorOSFrameWidth = 5120
private let monitorOSFrameHeight = 2880
private let monitorOSMaximumDeltaRects = 64
private let monitorOSFullFrameThresholdPixels =
    monitorOSFrameWidth * monitorOSFrameHeight * 4 / 5

func monitorOSNormalizeDamageRects(
    _ rects: [CGRect]
) -> [MonitorOSDamageRegion] {
    let frameBounds = CGRect(
        x: 0,
        y: 0,
        width: monitorOSFrameWidth,
        height: monitorOSFrameHeight
    )

    var regions: [MonitorOSDamageRegion] = []
    regions.reserveCapacity(rects.count)

    for rect in rects {
        let standardized = rect.standardized
        guard standardized.minX.isFinite,
              standardized.minY.isFinite,
              standardized.maxX.isFinite,
              standardized.maxY.isFinite else {
            continue
        }

        let clipped = standardized.intersection(frameBounds)
        if clipped.isNull || clipped.isEmpty {
            continue
        }

        var x0 = max(0, Int(floor(clipped.minX)))
        let y0 = max(0, Int(floor(clipped.minY)))
        var x1 = min(monitorOSFrameWidth, Int(ceil(clipped.maxX)))
        let y1 = min(monitorOSFrameHeight, Int(ceil(clipped.maxY)))

        if x0 % 2 != 0 {
            x0 -= 1
        }
        if x1 % 2 != 0 {
            x1 = min(monitorOSFrameWidth, x1 + 1)
        }

        guard x1 > x0, y1 > y0 else {
            continue
        }

        regions.append(
            MonitorOSDamageRegion(
                x: x0,
                y: y0,
                width: x1 - x0,
                height: y1 - y0
            )
        )
    }

    return monitorOSCoalesceDamageRegions(regions)
}

private func monitorOSCoalesceDamageRegions(
    _ regions: [MonitorOSDamageRegion]
) -> [MonitorOSDamageRegion] {
    var result = regions
    var index = 0

    while index < result.count {
        var candidate = index + 1
        while candidate < result.count {
            let first = result[index]
            let second = result[candidate]
            let overlaps =
                first.x < second.x + second.width
                && second.x < first.x + first.width
                && first.y < second.y + second.height
                && second.y < first.y + first.height

            if overlaps {
                let x0 = min(first.x, second.x)
                let y0 = min(first.y, second.y)
                let x1 = max(first.x + first.width, second.x + second.width)
                let y1 = max(first.y + first.height, second.y + second.height)
                result[index] = MonitorOSDamageRegion(
                    x: x0,
                    y: y0,
                    width: x1 - x0,
                    height: y1 - y0
                )
                result.remove(at: candidate)
                candidate = index + 1
            } else {
                candidate += 1
            }
        }
        index += 1
    }

    return result
}

enum MonitorOSPendingDamage: Equatable {
    case full
    case regions([MonitorOSDamageRegion])
}

enum MonitorOSFullDamageReason: String, Equatable {
    case initialFrame = "initial"
    case missingMetadata = "missing-metadata"
    case rectLimit = "rect-limit"
    case coverageThreshold = "coverage-threshold"
    case mergedRectLimit = "merged-rect-limit"
    case mergedCoverageThreshold = "merged-coverage-threshold"
    case contentRectLimit = "content-rect-limit"
    case contentCoverageThreshold = "content-coverage-threshold"
}

struct MonitorOSDamageDecision: Equatable {
    let damage: MonitorOSPendingDamage
    let pixelCount: Int?
    let rectCount: Int
    let fullReason: MonitorOSFullDamageReason?
    let candidateRegions: [MonitorOSDamageRegion]?

    init(
        damage: MonitorOSPendingDamage,
        pixelCount: Int?,
        rectCount: Int,
        fullReason: MonitorOSFullDamageReason?,
        candidateRegions: [MonitorOSDamageRegion]? = nil
    ) {
        self.damage = damage
        self.pixelCount = pixelCount
        self.rectCount = rectCount
        self.fullReason = fullReason
        self.candidateRegions = candidateRegions
    }
}

func monitorOSAnalyzeRegions(
    _ regions: [MonitorOSDamageRegion],
    rectLimitReason: MonitorOSFullDamageReason,
    coverageReason: MonitorOSFullDamageReason
) -> MonitorOSDamageDecision {
    let pixels = regions.reduce(0) { partial, region in
        partial + region.pixelCount
    }

    if regions.count > monitorOSMaximumDeltaRects {
        return MonitorOSDamageDecision(
            damage: .full,
            pixelCount: pixels,
            rectCount: regions.count,
            fullReason: rectLimitReason,
            candidateRegions: regions
        )
    }

    if pixels >= monitorOSFullFrameThresholdPixels {
        return MonitorOSDamageDecision(
            damage: .full,
            pixelCount: pixels,
            rectCount: regions.count,
            fullReason: coverageReason,
            candidateRegions: regions
        )
    }

    return MonitorOSDamageDecision(
        damage: .regions(regions),
        pixelCount: pixels,
        rectCount: regions.count,
        fullReason: nil,
        candidateRegions: regions
    )
}

func monitorOSDamageDecision(
    from rects: [CGRect]?
) -> MonitorOSDamageDecision {
    guard let rects else {
        return MonitorOSDamageDecision(
            damage: .full,
            pixelCount: nil,
            rectCount: 0,
            fullReason: .missingMetadata
        )
    }

    return monitorOSAnalyzeRegions(
        monitorOSNormalizeDamageRects(rects),
        rectLimitReason: .rectLimit,
        coverageReason: .coverageThreshold
    )
}

func monitorOSDamageState(
    from rects: [CGRect]?
) -> MonitorOSPendingDamage {
    monitorOSDamageDecision(from: rects).damage
}

func monitorOSMergeDamageDecision(
    _ first: MonitorOSDamageDecision,
    _ second: MonitorOSDamageDecision
) -> MonitorOSDamageDecision {
    guard let firstRegions = first.candidateRegions else {
        return first
    }
    guard let secondRegions = second.candidateRegions else {
        return second
    }

    return monitorOSAnalyzeRegions(
        monitorOSCoalesceDamageRegions(firstRegions + secondRegions),
        rectLimitReason: .mergedRectLimit,
        coverageReason: .mergedCoverageThreshold
    )
}

func monitorOSMergeDamage(
    _ first: MonitorOSPendingDamage,
    _ second: MonitorOSPendingDamage
) -> MonitorOSPendingDamage {
    switch (first, second) {
    case (.full, _), (_, .full):
        return .full
    case let (.regions(firstRegions), .regions(secondRegions)):
        return monitorOSAnalyzeRegions(
            monitorOSCoalesceDamageRegions(firstRegions + secondRegions),
            rectLimitReason: .mergedRectLimit,
            coverageReason: .mergedCoverageThreshold
        ).damage
    }
}

private struct FrameSendResult {
    let payloadBytes: Int
    let sendDurationSeconds: Double
    let conversionDurationSeconds: Double?
    let packingDurationSeconds: Double
    let isFullFrame: Bool
    let rectCount: Int
    let decision: MonitorOSDamageDecision
    let refinementDurationSeconds: Double
    let refinementApplied: Bool
    let refinementChangedPairCount: Int
    let refinementChangedWireByteCount: Int
    let refinementMeanWireByteDelta: Double
    let refinementMaxWireByteDelta: Int
}

private enum FrameSendOutcome {
    case sent(FrameSendResult)
    case unchanged(candidatePixels: Int)
}

struct MonitorOSTransportEndpoint: Equatable {
    let host: String
    let port: String

    init(target: String) throws {
        guard target.hasPrefix("["),
              let closingBracket = target.firstIndex(of: "]") else {
            throw Self.invalid(target)
        }
        let separator = target.index(after: closingBracket)
        guard separator < target.endIndex,
              target[separator] == ":" else {
            throw Self.invalid(target)
        }

        let host = String(
            target[target.index(after: target.startIndex)..<closingBracket]
        )
        let portText = String(target[target.index(after: separator)...])
        guard host.contains(":"),
              let port = UInt16(portText) else {
            throw Self.invalid(target)
        }

        self.host = host
        self.port = String(port)
    }

    private static func invalid(_ target: String) -> MonitorOSCaptureError {
        MonitorOSCaptureError(
            "invalid transport target \(target); expected [IPv6%scope]:PORT"
        )
    }
}

private final class TcpFrameSender: @unchecked Sendable {
    private static let magic = Array("MOS5K002".utf8)
    private static let headerSize = 64
    private static let rectDescriptorSize = 16

    private var socketFD: Int32
    private let yuv422Converter: YUV422Converter
    private let deltaStorage: UnsafeMutableRawPointer

    init(target: String) throws {
        yuv422Converter = try YUV422Converter()
        socketFD = try Self.connectSocket(to: target)

        var sendBufferBytes: Int32 = 0
        var sendBufferLength = socklen_t(MemoryLayout<Int32>.size)
        if getsockopt(
            socketFD,
            SOL_SOCKET,
            SO_SNDBUF,
            &sendBufferBytes,
            &sendBufferLength
        ) == 0 {
            fputs(
                "transport socket: SO_SNDBUF=\(sendBufferBytes) bytes\n",
                stderr
            )
        } else {
            fputs(
                "warning: getsockopt(SO_SNDBUF) failed: " +
                String(cString: strerror(errno)) + "\n",
                stderr
            )
        }

        deltaStorage = UnsafeMutableRawPointer.allocate(
            byteCount: YUV422Converter.byteCount,
            alignment: 64
        )
    }

    private static func connectSocket(to target: String) throws -> Int32 {
        let endpoint = try MonitorOSTransportEndpoint(target: target)

        var hints = addrinfo()
        hints.ai_family = AF_INET6
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP
        hints.ai_flags = AI_NUMERICSERV

        var addresses: UnsafeMutablePointer<addrinfo>?
        let resolveResult = endpoint.host.withCString { host in
            endpoint.port.withCString { port in
                getaddrinfo(host, port, &hints, &addresses)
            }
        }
        guard resolveResult == 0 else {
            throw MonitorOSCaptureError(
                "resolve(\(target)) failed: " +
                String(cString: gai_strerror(resolveResult))
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
                    "socket() failed: \(String(cString: strerror(errno)))"
                )
                address = info.ai_next
                continue
            }

            do {
                try configureSocket(fd)
                guard let socketAddress = info.ai_addr else {
                    throw MonitorOSCaptureError(
                        "resolved transport target has no socket address"
                    )
                }
                try connectSocket(
                    fd,
                    to: socketAddress,
                    length: info.ai_addrlen,
                    target: target
                )
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
            "resolve(\(target)) returned no usable addresses"
        )
    }

    private static func configureSocket(_ fd: Int32) throws {
        var noSigPipe: Int32 = 1
        guard setsockopt(
            fd,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSigPipe,
            socklen_t(MemoryLayout<Int32>.size)
        ) == 0 else {
            throw MonitorOSCaptureError(
                "setsockopt(SO_NOSIGPIPE) failed: " +
                String(cString: strerror(errno))
            )
        }

        var sendTimeout = timeval(tv_sec: 5, tv_usec: 0)
        guard setsockopt(
            fd,
            SOL_SOCKET,
            SO_SNDTIMEO,
            &sendTimeout,
            socklen_t(MemoryLayout<timeval>.size)
        ) == 0 else {
            throw MonitorOSCaptureError(
                "setsockopt(SO_SNDTIMEO) failed: " +
                String(cString: strerror(errno))
            )
        }
    }

    private static func connectSocket(
        _ fd: Int32,
        to address: UnsafePointer<sockaddr>,
        length: socklen_t,
        target: String
    ) throws {
        let originalFlags = fcntl(fd, F_GETFL)
        guard originalFlags >= 0 else {
            throw MonitorOSCaptureError(
                "fcntl(F_GETFL) failed: \(String(cString: strerror(errno)))"
            )
        }

        guard fcntl(fd, F_SETFL, originalFlags | O_NONBLOCK) == 0 else {
            throw MonitorOSCaptureError(
                "fcntl(F_SETFL, O_NONBLOCK) failed: " +
                String(cString: strerror(errno))
            )
        }

        let connectResult = Darwin.connect(fd, address, length)
        if connectResult != 0 {
            guard errno == EINPROGRESS else {
                throw MonitorOSCaptureError(
                    "connect(\(target)) failed: " +
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
                let message = pollResult == 0
                    ? "timed out after 1.0 s"
                    : String(cString: strerror(errno))
                throw MonitorOSCaptureError(
                    "connect(\(target)) failed: \(message)"
                )
            }

            var socketError: Int32 = 0
            var socketErrorLength = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(
                fd,
                SOL_SOCKET,
                SO_ERROR,
                &socketError,
                &socketErrorLength
            ) == 0 else {
                throw MonitorOSCaptureError(
                    "getsockopt(SO_ERROR) failed: " +
                    String(cString: strerror(errno))
                )
            }

            guard socketError == 0 else {
                throw MonitorOSCaptureError(
                    "connect(\(target)) failed: " +
                    String(cString: strerror(socketError))
                )
            }
        }

        guard fcntl(fd, F_SETFL, originalFlags) == 0 else {
            throw MonitorOSCaptureError(
                "failed to restore socket flags: " +
                String(cString: strerror(errno))
            )
        }
    }

    deinit {
        deltaStorage.deallocate()
        if socketFD >= 0 {
            Darwin.close(socketFD)
        }
    }

    func sendFrame(
        pixelBuffer: CVPixelBuffer,
        frameID: UInt64,
        ptsNanos: UInt64,
        decision: MonitorOSDamageDecision
    ) throws -> FrameSendOutcome {
        try sendYUV422(
            pixelBuffer: pixelBuffer,
            frameID: frameID,
            ptsNanos: ptsNanos,
            decision: decision
        )
    }

    private func sendYUV422(
        pixelBuffer: CVPixelBuffer,
        frameID: UInt64,
        ptsNanos: UInt64,
        decision: MonitorOSDamageDecision
    ) throws -> FrameSendOutcome {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer)
                == kCVPixelFormatType_32BGRA else {
            throw MonitorOSCaptureError(
                "4:2:2 transport expected ScreenCaptureKit BGRA buffers"
            )
        }
        guard CVPixelBufferGetWidth(pixelBuffer) == YUV422Converter.width,
              CVPixelBufferGetHeight(pixelBuffer) == YUV422Converter.height,
              CVPixelBufferGetPlaneCount(pixelBuffer) == 0 else {
            throw MonitorOSCaptureError(
                "4:2:2 transport expected packed 5120x2880 BGRA"
            )
        }

        let effectiveDecision: MonitorOSDamageDecision
        if frameID == 0 {
            effectiveDecision = MonitorOSDamageDecision(
                damage: .full,
                pixelCount: nil,
                rectCount: 0,
                fullReason: .initialFrame
            )
        } else {
            effectiveDecision = decision
        }

        let converter = yuv422Converter
        let conversionDamage = converter.conversionDamage(
            for: effectiveDecision
        )
        let converted = try converter.convert(
            pixelBuffer: pixelBuffer,
            damage: conversionDamage
        )
        let refinement = try converter.refineConvertedDamage(
            decision: effectiveDecision
        )
        let refinedDecision = refinement.decision

        if case let .regions(regions) = refinedDecision.damage,
           regions.isEmpty {
            return .unchanged(
                candidatePixels: effectiveDecision.pixelCount ?? 0
            )
        }

        switch refinedDecision.damage {
        case .full:
            let header = try makeHeader(
                frameID: frameID,
                ptsNanos: ptsNanos,
                fourCC: kCVPixelFormatType_422YpCbCr8FullRange,
                planeCount: 1,
                stride0: YUV422Converter.stride,
                stride1: 0,
                size0: YUV422Converter.byteCount,
                size1: 0,
                rectCount: 0
            )

            let start = DispatchTime.now().uptimeNanoseconds
            try sendHeader(header)
            try sendAll(converted.base, count: YUV422Converter.byteCount)
            let end = DispatchTime.now().uptimeNanoseconds
            try converter.commitReference(damage: conversionDamage)

            return .sent(
                FrameSendResult(
                    payloadBytes: YUV422Converter.byteCount,
                    sendDurationSeconds: Double(end - start) / 1_000_000_000,
                    conversionDurationSeconds: converted.durationSeconds,
                    packingDurationSeconds: 0,
                    isFullFrame: true,
                    rectCount: 0,
                    decision: refinedDecision,
                    refinementDurationSeconds: refinement.durationSeconds,
                    refinementApplied: refinement.applied,
                    refinementChangedPairCount:
                        refinement.changedPairCount,
                    refinementChangedWireByteCount:
                        refinement.changedWireByteCount,
                    refinementMeanWireByteDelta:
                        refinement.meanWireByteDelta,
                    refinementMaxWireByteDelta:
                        refinement.maxWireByteDelta
                )
            )

        case let .regions(regions):
            var descriptors = [UInt8](
                repeating: 0,
                count: regions.count * Self.rectDescriptorSize
            )
            var payloadBytes = 0
            let packingStart = DispatchTime.now().uptimeNanoseconds

            for (index, region) in regions.enumerated() {
                let descriptorOffset = index * Self.rectDescriptorSize
                putUInt32(
                    UInt32(region.x),
                    into: &descriptors,
                    at: descriptorOffset
                )
                putUInt32(
                    UInt32(region.y),
                    into: &descriptors,
                    at: descriptorOffset + 4
                )
                putUInt32(
                    UInt32(region.width),
                    into: &descriptors,
                    at: descriptorOffset + 8
                )
                putUInt32(
                    UInt32(region.height),
                    into: &descriptors,
                    at: descriptorOffset + 12
                )

                let rowBytes = region.width * 2
                for row in 0..<region.height {
                    let sourceOffset =
                        (region.y + row) * YUV422Converter.stride
                        + region.x * 2
                    deltaStorage
                        .advanced(by: payloadBytes)
                        .copyMemory(
                            from: converted.base.advanced(by: sourceOffset),
                            byteCount: rowBytes
                        )
                    payloadBytes += rowBytes
                }
            }

            let packingEnd = DispatchTime.now().uptimeNanoseconds
            let packingDurationSeconds =
                Double(packingEnd - packingStart) / 1_000_000_000

            let header = try makeHeader(
                frameID: frameID,
                ptsNanos: ptsNanos,
                fourCC: kCVPixelFormatType_422YpCbCr8FullRange,
                planeCount: 1,
                stride0: YUV422Converter.stride,
                stride1: 0,
                size0: payloadBytes,
                size1: 0,
                rectCount: regions.count
            )

            let start = DispatchTime.now().uptimeNanoseconds
            try sendHeader(header)
            try sendBytes(descriptors)
            try sendAll(deltaStorage, count: payloadBytes)
            let end = DispatchTime.now().uptimeNanoseconds
            try converter.commitReference(damage: conversionDamage)

            return .sent(
                FrameSendResult(
                    payloadBytes: descriptors.count + payloadBytes,
                    sendDurationSeconds: Double(end - start) / 1_000_000_000,
                    conversionDurationSeconds: converted.durationSeconds,
                    packingDurationSeconds: packingDurationSeconds,
                    isFullFrame: false,
                    rectCount: regions.count,
                    decision: refinedDecision,
                    refinementDurationSeconds: refinement.durationSeconds,
                    refinementApplied: refinement.applied,
                    refinementChangedPairCount:
                        refinement.changedPairCount,
                    refinementChangedWireByteCount:
                        refinement.changedWireByteCount,
                    refinementMeanWireByteDelta:
                        refinement.meanWireByteDelta,
                    refinementMaxWireByteDelta:
                        refinement.maxWireByteDelta
                )
            )
        }
    }

    private func makeHeader(
        frameID: UInt64,
        ptsNanos: UInt64,
        fourCC: OSType,
        planeCount: Int,
        stride0: Int,
        stride1: Int,
        size0: Int,
        size1: Int,
        rectCount: Int
    ) throws -> [UInt8] {
        guard stride0 <= Int(UInt32.max),
              stride1 <= Int(UInt32.max),
              size0 <= Int(UInt32.max),
              size1 <= Int(UInt32.max),
              rectCount <= Int(UInt32.max) else {
            throw MonitorOSCaptureError(
                "frame metadata exceeds transport protocol limits"
            )
        }

        var header = [UInt8](repeating: 0, count: Self.headerSize)
        header.replaceSubrange(0..<8, with: Self.magic)
        putUInt32(UInt32(Self.headerSize), into: &header, at: 8)
        putUInt64(frameID, into: &header, at: 12)
        putUInt64(ptsNanos, into: &header, at: 20)
        putUInt32(5120, into: &header, at: 28)
        putUInt32(2880, into: &header, at: 32)
        putUInt32(fourCC, into: &header, at: 36)
        putUInt32(UInt32(planeCount), into: &header, at: 40)
        putUInt32(UInt32(stride0), into: &header, at: 44)
        putUInt32(UInt32(stride1), into: &header, at: 48)
        putUInt32(UInt32(size0), into: &header, at: 52)
        putUInt32(UInt32(size1), into: &header, at: 56)
        putUInt32(UInt32(rectCount), into: &header, at: 60)
        return header
    }

    private func sendHeader(_ header: [UInt8]) throws {
        try header.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else {
                throw MonitorOSCaptureError(
                    "failed to access transport header"
                )
            }
            try sendAll(base, count: bytes.count)
        }
    }


    private func sendBytes(_ bytes: [UInt8]) throws {
        try bytes.withUnsafeBytes { rawBytes in
            guard let base = rawBytes.baseAddress else {
                return
            }
            try sendAll(base, count: rawBytes.count)
        }
    }

    private func sendAll(_ base: UnsafeRawPointer, count: Int) throws {
        var offset = 0
        while offset < count {
            let sent = Darwin.send(
                socketFD,
                base.advanced(by: offset),
                count - offset,
                0
            )
            if sent < 0 {
                if errno == EINTR {
                    continue
                }
                throw MonitorOSCaptureError(
                    "send() failed: \(String(cString: strerror(errno)))"
                )
            }
            if sent == 0 {
                throw MonitorOSCaptureError(
                    "send() returned zero before payload completed"
                )
            }
            offset += sent
        }
    }

    private func putUInt32(
        _ value: UInt32,
        into bytes: inout [UInt8],
        at offset: Int
    ) {
        bytes[offset] = UInt8((value >> 24) & 0xff)
        bytes[offset + 1] = UInt8((value >> 16) & 0xff)
        bytes[offset + 2] = UInt8((value >> 8) & 0xff)
        bytes[offset + 3] = UInt8(value & 0xff)
    }

    private func putUInt64(
        _ value: UInt64,
        into bytes: inout [UInt8],
        at offset: Int
    ) {
        for index in 0..<8 {
            let shift = UInt64((7 - index) * 8)
            bytes[offset + index] = UInt8((value >> shift) & 0xff)
        }
    }
}

private struct PendingTransportFrame {
    let pixelBuffer: CVPixelBuffer
    let ptsNanos: UInt64
    let decision: MonitorOSDamageDecision

    var damage: MonitorOSPendingDamage {
        decision.damage
    }
}

public struct MonitorOSTransportSnapshot: Sendable {
    public let submittedFrames: Int
    public let replacedFrames: Int
    public let skippedFrames: Int
    public let sentFrames: Int
    public let refinedFrames: Int
    public let contentSkippedFrames: Int
    public let refinementCandidatePixels: UInt64
    public let refinementTileCoveragePixels: UInt64
    public let refinementChangedPairs: UInt64
    public let refinementChangedWireBytes: UInt64
    public let error: String?
}

public final class MonitorOSAsyncFrameTransport: @unchecked Sendable {
    private let sender: TcpFrameSender
    private let worker = DispatchQueue(
        label: "org.monitoros.capture.transport",
        qos: .userInteractive
    )
    private let lock = NSLock()

    private var pendingFrame: PendingTransportFrame?
    private var workerScheduled = false
    private var nextFrameID: UInt64 = 0
    private var submittedFrames = 0
    private var replacedFrames = 0
    private var skippedFrames = 0
    private var sentFrames = 0
    private var refinedFrames = 0
    private var contentSkippedFrames = 0
    private var refinementCandidatePixels: UInt64 = 0
    private var refinementTileCoveragePixels: UInt64 = 0
    private var refinementChangedPairs: UInt64 = 0
    private var refinementChangedWireBytes: UInt64 = 0
    private var transportError: String?

    public init(target: String) throws {
        sender = try TcpFrameSender(target: target)
    }

    public var error: String? {
        lock.lock()
        defer { lock.unlock() }
        return transportError
    }

    public func submit(
        pixelBuffer: CVPixelBuffer,
        ptsNanos: UInt64,
        damageRects: [CGRect]? = nil
    ) {
        var shouldSchedule = false

        lock.lock()
        if transportError == nil {
            submittedFrames += 1

            let needsInitialFull =
                nextFrameID == 0
                && pendingFrame == nil
                && !workerScheduled
            let incomingDecision: MonitorOSDamageDecision
            if needsInitialFull {
                incomingDecision = MonitorOSDamageDecision(
                    damage: .full,
                    pixelCount: nil,
                    rectCount: 0,
                    fullReason: .initialFrame
                )
            } else {
                incomingDecision = monitorOSDamageDecision(
                    from: damageRects
                )
            }

            if case let .regions(regions) = incomingDecision.damage,
               regions.isEmpty {
                skippedFrames += 1
                lock.unlock()
                return
            }

            if let pendingFrame {
                replacedFrames += 1
                self.pendingFrame = PendingTransportFrame(
                    pixelBuffer: pixelBuffer,
                    ptsNanos: ptsNanos,
                    decision: monitorOSMergeDamageDecision(
                        pendingFrame.decision,
                        incomingDecision
                    )
                )
            } else {
                pendingFrame = PendingTransportFrame(
                    pixelBuffer: pixelBuffer,
                    ptsNanos: ptsNanos,
                    decision: incomingDecision
                )
            }

            if !workerScheduled {
                workerScheduled = true
                shouldSchedule = true
            }
        }
        lock.unlock()

        if shouldSchedule {
            worker.async { [self] in
                drain()
            }
        }
    }

    public func finish() -> MonitorOSTransportSnapshot {
        worker.sync {}
        return snapshot()
    }

    public func snapshot() -> MonitorOSTransportSnapshot {
        lock.lock()
        defer { lock.unlock() }

        return MonitorOSTransportSnapshot(
            submittedFrames: submittedFrames,
            replacedFrames: replacedFrames,
            skippedFrames: skippedFrames,
            sentFrames: sentFrames,
            refinedFrames: refinedFrames,
            contentSkippedFrames: contentSkippedFrames,
            refinementCandidatePixels: refinementCandidatePixels,
            refinementTileCoveragePixels: refinementTileCoveragePixels,
            refinementChangedPairs: refinementChangedPairs,
            refinementChangedWireBytes: refinementChangedWireBytes,
            error: transportError
        )
    }

    private func drain() {
        while true {
            lock.lock()
            guard let frame = pendingFrame, transportError == nil else {
                pendingFrame = nil
                workerScheduled = false
                lock.unlock()
                return
            }
            pendingFrame = nil
            let frameID = nextFrameID
            lock.unlock()

            do {
                let outcome = try sender.sendFrame(
                    pixelBuffer: frame.pixelBuffer,
                    frameID: frameID,
                    ptsNanos: frame.ptsNanos,
                    decision: frame.decision
                )

                guard case let .sent(result) = outcome else {
                    if case let .unchanged(candidatePixels) = outcome {
                        lock.lock()
                        skippedFrames += 1
                        contentSkippedFrames += 1
                        refinedFrames += 1
                        refinementCandidatePixels += UInt64(candidatePixels)
                        lock.unlock()
                    }
                    continue
                }

                lock.lock()
                nextFrameID &+= 1
                sentFrames += 1
                if result.refinementApplied {
                    refinedFrames += 1
                    refinementCandidatePixels += UInt64(
                        frame.decision.pixelCount ?? 0
                    )
                    refinementTileCoveragePixels += UInt64(
                        result.decision.pixelCount ?? 0
                    )
                    refinementChangedPairs += UInt64(
                        result.refinementChangedPairCount
                    )
                    refinementChangedWireBytes += UInt64(
                        result.refinementChangedWireByteCount
                    )
                }
                lock.unlock()

                let conversionSeconds =
                    result.conversionDurationSeconds ?? 0
                let pipelineSeconds =
                    result.refinementDurationSeconds
                    + conversionSeconds
                    + result.packingDurationSeconds
                    + result.sendDurationSeconds

                if pipelineSeconds > (1.0 / 60.0)
                    || conversionSeconds > 0.010
                    || result.packingDurationSeconds > 0.005 {
                    let kind = result.isFullFrame ? "FULL" : "DELTA"
                    func percentText(_ pixels: Int?) -> String {
                        guard let pixels else {
                            return "n/a"
                        }
                        return String(
                            format: "%.1f%%",
                            Double(pixels) * 100.0
                                / Double(
                                    monitorOSFrameWidth
                                        * monitorOSFrameHeight
                                )
                        )
                    }
                    let damageText: String
                    if result.refinementApplied {
                        let totalPairs =
                            Double(YUV422Converter.width)
                                * Double(YUV422Converter.height) / 2.0
                        let pairChangedPercent =
                            Double(result.refinementChangedPairCount)
                                * 100.0 / totalPairs
                        let wireChangedPercent =
                            Double(result.refinementChangedWireByteCount)
                                * 100.0
                                / Double(YUV422Converter.byteCount)
                        damageText =
                            "candidate=\(percentText(frame.decision.pixelCount)) " +
                            "tile-coverage=\(percentText(result.decision.pixelCount)) " +
                            String(
                                format:
                                    "pair-changed=%.2f%% wire-changed=%.2f%%",
                                pairChangedPercent,
                                wireChangedPercent
                            )
                    } else {
                        damageText =
                            "damage=\(percentText(result.decision.pixelCount))"
                    }
                    let reason =
                        result.decision.fullReason?.rawValue ?? "delta"
                    let payloadMiB =
                        Double(result.payloadBytes) / (1024.0 * 1024.0)
                    let sendGbps =
                        result.sendDurationSeconds > 0
                        ? Double(result.payloadBytes) * 8.0
                            / result.sendDurationSeconds / 1_000_000_000.0
                        : 0

                    let timingText = String(
                        format:
                            "yuv-delta=%.2f/%d bytes=%.2fMiB " +
                            "diff=%.3fms metal=%.3fms " +
                            "pack=%.3fms send=%.3fms " +
                            "rate=%.2fGb/s total=%.3fms",
                        result.refinementMeanWireByteDelta,
                        result.refinementMaxWireByteDelta,
                        payloadMiB,
                        result.refinementDurationSeconds * 1000,
                        conversionSeconds * 1000,
                        result.packingDurationSeconds * 1000,
                        result.sendDurationSeconds * 1000,
                        sendGbps,
                        pipelineSeconds * 1000
                    )
                    fputs(
                        "slow frame pipeline: frame=\(frameID) " +
                        "type=\(kind) rects=\(result.decision.rectCount) " +
                        "\(damageText) reason=\(reason) " +
                        timingText + "\n",
                        stderr
                    )
                }
            } catch {
                lock.lock()
                transportError = String(describing: error)
                pendingFrame = nil
                workerScheduled = false
                lock.unlock()
                return
            }
        }
    }
}

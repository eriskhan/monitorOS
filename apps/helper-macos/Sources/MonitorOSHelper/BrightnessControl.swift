import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation
import MonitorOSCapture

private let monitorOSControlPort = "5203"
private let monitorOSBrightnessMagic = Array("MOSBRT01".utf8)
private let monitorOSBrightnessSetMagic = Array("MOSBRS01".utf8)
private let monitorOSBrightnessQueryMagic = Array("MOSBRQ01".utf8)
private let monitorOSBrightnessResponseMagic = Array("MOSBRV01".utf8)
private let monitorOSVolumeSetMagic = Array("MOSVLS01".utf8)
private let monitorOSVolumeResponseMagic = Array("MOSVLR01".utf8)
private let monitorOSMuteSetMagic = Array("MOSMTS01".utf8)
private let monitorOSMuteResponseMagic = Array("MOSMTR01".utf8)
private let monitorOSBrightnessFineSteps: Float = 64
private let monitorOSVolumeWireSteps: Float = 255

fileprivate enum MonitorOSBrightnessCommand: UInt8 {
    case down = 1
    case up = 2
    case fineDown = 3
    case fineUp = 4

    var delta: Int {
        switch self {
        case .down:
            return -4
        case .up:
            return 4
        case .fineDown:
            return -1
        case .fineUp:
            return 1
        }
    }

    static func make(
        down: Bool,
        fine: Bool
    ) -> MonitorOSBrightnessCommand {
        switch (down, fine) {
        case (true, false):
            return .down
        case (false, false):
            return .up
        case (true, true):
            return .fineDown
        case (false, true):
            return .fineUp
        }
    }
}

private struct MonitorOSControlEndpoint: Equatable {
    let host: String
    let port: String

    init(videoTarget: String) throws {
        guard videoTarget.hasPrefix("["),
              let closingBracket = videoTarget.firstIndex(of: "]") else {
            throw MonitorOSCaptureError(
                "invalid control target derived from \(videoTarget)"
            )
        }
        host = String(
            videoTarget[
                videoTarget.index(after: videoTarget.startIndex)..<closingBracket
            ]
        )
        guard host.contains(":") else {
            throw MonitorOSCaptureError(
                "invalid control target derived from \(videoTarget)"
            )
        }
        port = monitorOSControlPort
    }
}

final class MonitorOSControlSender: @unchecked Sendable {
    private let endpoint: MonitorOSControlEndpoint
    private let queue = DispatchQueue(
        label: "org.monitoros.helper.control",
        qos: .userInitiated
    )
    private var socketFD: Int32 = -1
    private let setLock = NSLock()
    private var pendingSet: (
        unit: UInt8,
        completion: (Float) -> Void
    )?
    private var setDrainActive = false
    private let volumeLock = NSLock()
    private var pendingVolumeUnit: UInt8?
    private var volumeDrainActive = false

    init(videoTarget: String) throws {
        endpoint = try MonitorOSControlEndpoint(videoTarget: videoTarget)
    }

    deinit {
        if socketFD >= 0 {
            Darwin.close(socketFD)
        }
    }

    fileprivate func send(
        _ command: MonitorOSBrightnessCommand,
        completion: @escaping (Float) -> Void
    ) {
        var message = monitorOSBrightnessMagic
        message.append(command.rawValue)
        enqueueBrightness(message: message, completion: completion)
    }

    fileprivate func query(completion: @escaping (Float) -> Void) {
        var message = monitorOSBrightnessQueryMagic
        message.append(0)
        enqueueBrightness(message: message, completion: completion)
    }

    func setVolume(_ scalar: Float) {
        let clamped = min(1, max(0, scalar.isFinite ? scalar : 0))
        let unit = UInt8((clamped * monitorOSVolumeWireSteps).rounded())

        volumeLock.lock()
        pendingVolumeUnit = unit
        let shouldStartDrain = !volumeDrainActive
        if shouldStartDrain {
            volumeDrainActive = true
        }
        volumeLock.unlock()

        if shouldStartDrain {
            queue.async { [self] in
                drainPendingVolumes()
            }
        }
    }

    func setMute(_ muted: Bool) {
        queue.async { [self] in
            var message = monitorOSMuteSetMagic
            message.append(muted ? 1 : 0)
            do {
                _ = try exchange(
                    message,
                    responseMagic: monitorOSMuteResponseMagic
                )
            } catch {
                resetSocket()
                fputs(
                    "monitorOS Helper: speaker mute control failed: \(error)\n",
                    stderr
                )
            }
        }
    }

    fileprivate func set(
        fineUnit: UInt8,
        completion: @escaping (Float) -> Void
    ) {
        guard fineUnit <= UInt8(monitorOSBrightnessFineSteps) else {
            return
        }

        setLock.lock()
        pendingSet = (fineUnit, completion)
        let shouldStartDrain = !setDrainActive
        if shouldStartDrain {
            setDrainActive = true
        }
        setLock.unlock()

        if shouldStartDrain {
            queue.async { [self] in
                drainPendingSets()
            }
        }
    }

    private func drainPendingSets() {
        while true {
            setLock.lock()
            guard let request = pendingSet else {
                setDrainActive = false
                setLock.unlock()
                return
            }
            pendingSet = nil
            setLock.unlock()

            var message = monitorOSBrightnessSetMagic
            message.append(request.unit)

            do {
                let value = try exchange(
                    message,
                    responseMagic: monitorOSBrightnessResponseMagic
                )
                request.completion(
                    Float(value) / monitorOSBrightnessFineSteps
                )
            } catch {
                resetSocket()
                fputs(
                    "monitorOS Helper: brightness slider control failed: \(error)\n",
                    stderr
                )
            }
        }
    }

    private func drainPendingVolumes() {
        while true {
            volumeLock.lock()
            guard let unit = pendingVolumeUnit else {
                volumeDrainActive = false
                volumeLock.unlock()
                return
            }
            pendingVolumeUnit = nil
            volumeLock.unlock()

            var message = monitorOSVolumeSetMagic
            message.append(unit)

            do {
                _ = try exchange(
                    message,
                    responseMagic: monitorOSVolumeResponseMagic
                )
            } catch {
                resetSocket()
                fputs(
                    "monitorOS Helper: speaker volume control failed: \(error)\n",
                    stderr
                )
            }
        }
    }

    private func enqueueBrightness(
        message: [UInt8],
        completion: @escaping (Float) -> Void
    ) {
        queue.async { [self] in
            do {
                let value = try exchange(
                    message,
                    responseMagic: monitorOSBrightnessResponseMagic
                )
                completion(Float(value) / monitorOSBrightnessFineSteps)
            } catch {
                resetSocket()
                fputs(
                    "monitorOS Helper: brightness control failed: \(error)\n",
                    stderr
                )
            }
        }
    }

    private func resetSocket() {
        if socketFD >= 0 {
            Darwin.close(socketFD)
            socketFD = -1
        }
    }

    private func exchange(
        _ message: [UInt8],
        responseMagic: [UInt8]
    ) throws -> UInt8 {
        if socketFD < 0 {
            socketFD = try connectSocket()
            print(
                "monitorOS Helper: control connected to " +
                "\(endpoint.host):\(endpoint.port)"
            )
        }

        try message.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else {
                throw MonitorOSCaptureError(
                    "failed to access control message"
                )
            }

            var offset = 0
            while offset < bytes.count {
                let sent = Darwin.send(
                    socketFD,
                    base.advanced(by: offset),
                    bytes.count - offset,
                    0
                )
                if sent < 0 {
                    if errno == EINTR {
                        continue
                    }
                    throw MonitorOSCaptureError(
                        "control send() failed: " +
                        String(cString: strerror(errno))
                    )
                }
                if sent == 0 {
                    throw MonitorOSCaptureError(
                        "control send() returned zero"
                    )
                }
                offset += sent
            }
        }

        var response = [UInt8](
            repeating: 0,
            count: responseMagic.count + 1
        )
        try response.withUnsafeMutableBytes { bytes in
            guard let base = bytes.baseAddress else {
                throw MonitorOSCaptureError(
                    "failed to access control response buffer"
                )
            }

            var offset = 0
            while offset < bytes.count {
                let received = Darwin.recv(
                    socketFD,
                    base.advanced(by: offset),
                    bytes.count - offset,
                    0
                )
                if received < 0 {
                    if errno == EINTR {
                        continue
                    }
                    throw MonitorOSCaptureError(
                        "control recv() failed: " +
                        String(cString: strerror(errno))
                    )
                }
                if received == 0 {
                    throw MonitorOSCaptureError(
                        "control connection closed before reply"
                    )
                }
                offset += received
            }
        }

        guard Array(response.prefix(responseMagic.count))
                == responseMagic else {
            throw MonitorOSCaptureError(
                "control returned invalid response magic"
            )
        }

        return response[responseMagic.count]
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
                "control resolve failed: " +
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
                    "control socket() failed: " +
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
                        "control setsockopt(SO_NOSIGPIPE) failed"
                    )
                }

                var receiveTimeout = timeval(
                    tv_sec: 0,
                    tv_usec: 500_000
                )
                guard setsockopt(
                    fd,
                    SOL_SOCKET,
                    SO_RCVTIMEO,
                    &receiveTimeout,
                    socklen_t(MemoryLayout<timeval>.size)
                ) == 0 else {
                    throw MonitorOSCaptureError(
                        "control setsockopt(SO_RCVTIMEO) failed"
                    )
                }

                guard let socketAddress = info.ai_addr else {
                    throw MonitorOSCaptureError(
                        "control target has no socket address"
                    )
                }

                let originalFlags = fcntl(fd, F_GETFL)
                guard originalFlags >= 0,
                      fcntl(fd, F_SETFL, originalFlags | O_NONBLOCK) == 0 else {
                    throw MonitorOSCaptureError(
                        "control fcntl(O_NONBLOCK) failed"
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
                            "control connect failed: " +
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
                                ? "control connect timed out after 1.0 s"
                                : "control connect poll failed: " +
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
                            "control connect failed: " +
                            String(cString: strerror(code))
                        )
                    }
                }

                guard fcntl(fd, F_SETFL, originalFlags) == 0 else {
                    throw MonitorOSCaptureError(
                        "control failed to restore socket flags"
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
            "brightness target resolved to no usable addresses"
        )
    }
}

private let monitorOSBrightnessEventTapCallback: CGEventTapCallBack = {
    _, type, event, userInfo in
    guard let userInfo else {
        return Unmanaged.passUnretained(event)
    }

    let hotkeys = Unmanaged<MonitorOSBrightnessHotkeys>
        .fromOpaque(userInfo)
        .takeUnretainedValue()

    let shouldConsume = MainActor.assumeIsolated {
        hotkeys.handleTapEvent(type: type, event: event)
    }
    return shouldConsume ? nil : Unmanaged.passUnretained(event)
}

@MainActor
final class MonitorOSBrightnessHotkeys {
    private static let nxSystemDefined = CGEventType(rawValue: 14)!
    private static let nxAuxControlSubtype: Int16 = 8
    private static let nxBrightnessUp = 2
    private static let nxBrightnessDown = 3

    // macOS 26 can also emit a plain-key leg for brightness.
    private static let brightnessKeycodeUp: Int64 = 144
    private static let brightnessKeycodeDown: Int64 = 145
    private static let standardF1: Int64 = 122
    private static let standardF2: Int64 = 120
    private static let auxTwinWindow: TimeInterval = 0.5
    private static let fallbackDelay = Duration.milliseconds(60)
    private static let cachedFineUnitKey =
        "org.monitoros.helper.lastBrightnessFineUnit"

    private let displayID: CGDirectDisplayID
    private let sender: MonitorOSControlSender
    private let hud: MonitorOSBrightnessHUD
    private var lastSliderFineUnit: UInt8?
    private var displayedFineUnit: UInt8
    private var eventTap: CFMachPort?
    private var eventTapSource: CFRunLoopSource?
    private var permissionTimer: Timer?
    private var lastAuxTimestamp: TimeInterval = 0
    private var activeDisplayID: CGDirectDisplayID?

    init(displayID: CGDirectDisplayID, videoTarget: String) throws {
        self.displayID = displayID
        sender = try MonitorOSControlSender(videoTarget: videoTarget)

        let cached = UserDefaults.standard.integer(
            forKey: Self.cachedFineUnitKey
        )
        displayedFineUnit = UInt8(
            min(
                Int(monitorOSBrightnessFineSteps),
                max(
                    0,
                    UserDefaults.standard.object(
                        forKey: Self.cachedFineUnitKey
                    ) == nil ? 32 : cached
                )
            )
        )

        hud = MonitorOSBrightnessHUD(
            movable: false,
            acceptsInput: true,
            showsCloseButton: false
        )
        hud.onBrightnessChange = { [weak self] value in
            self?.setBrightnessFromSlider(value)
        }

        // Do not put the initial state query on the same serial connection
        // used by live key/slider updates. A slow/unavailable query must never
        // delay the first F1/F2 event or prevent the HUD from appearing.
        let querySender = try MonitorOSControlSender(
            videoTarget: videoTarget
        )
        querySender.query { [weak self, querySender] value in
            _ = querySender
            Task { @MainActor in
                guard let self, self.lastSliderFineUnit == nil else {
                    return
                }
                let unit = self.fineUnit(from: value)
                self.lastSliderFineUnit = unit
                self.displayedFineUnit = unit
                self.cacheFineUnit(unit)
            }
        }

        if let event = CGEvent(source: nil) {
            activeDisplayID = displayIDForPoint(event.location)
        }

        requestAccessibilityPermissionIfNeeded()
        if !installEventTapIfAuthorized() {
            print(
                "monitorOS Helper: brightness hotkeys waiting for " +
                "Accessibility permission"
            )
            permissionTimer = Timer.scheduledTimer(
                withTimeInterval: 1.0,
                repeats: true
            ) { [weak self] timer in
                Task { @MainActor in
                    guard let self else {
                        timer.invalidate()
                        return
                    }
                    if self.installEventTapIfAuthorized() {
                        timer.invalidate()
                        self.permissionTimer = nil
                    }
                }
            }
        }
    }

    func stop() {
        permissionTimer?.invalidate()
        permissionTimer = nil
        uninstallEventTap()
    }

    private func requestAccessibilityPermissionIfNeeded() {
        guard !AXIsProcessTrusted() else {
            return
        }

        let promptKey =
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [promptKey: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    private func installEventTapIfAuthorized() -> Bool {
        if eventTap != nil {
            return true
        }
        guard AXIsProcessTrusted() else {
            return false
        }

        let mask =
            (CGEventMask(1) << Self.nxSystemDefined.rawValue)
            | (CGEventMask(1) << CGEventType.keyDown.rawValue)
            | (CGEventMask(1) << CGEventType.keyUp.rawValue)
            | (CGEventMask(1) << CGEventType.leftMouseDown.rawValue)
            | (CGEventMask(1) << CGEventType.rightMouseDown.rawValue)
            | (CGEventMask(1) << CGEventType.otherMouseDown.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: monitorOSBrightnessEventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            fputs(
                "monitorOS Helper: failed to create brightness event tap " +
                "despite Accessibility trust\n",
                stderr
            )
            return false
        }

        guard let source = CFMachPortCreateRunLoopSource(
            kCFAllocatorDefault,
            tap,
            0
        ) else {
            CFMachPortInvalidate(tap)
            fputs(
                "monitorOS Helper: failed to create brightness event-tap source\n",
                stderr
            )
            return false
        }

        eventTap = tap
        eventTapSource = source
        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            source,
            .commonModes
        )
        CGEvent.tapEnable(tap: tap, enable: true)

        print(
            "monitorOS Helper: F1/F2 brightness event tap enabled for " +
            "display id=\(displayID)"
        )
        return true
    }

    private func uninstallEventTap() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = eventTapSource {
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(),
                source,
                .commonModes
            )
            eventTapSource = nil
        }
        if let tap = eventTap {
            CFMachPortInvalidate(tap)
            eventTap = nil
        }
    }

    fileprivate func handleTapEvent(
        type: CGEventType,
        event: CGEvent
    ) -> Bool {
        if type == .tapDisabledByTimeout
            || type == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return false
        }

        if type == .leftMouseDown
            || type == .rightMouseDown
            || type == .otherMouseDown {
            updateActiveDisplay(from: event)
            return false
        }

        if type == .keyDown || type == .keyUp {
            return handlePlainKeyEvent(type: type, event: event)
        }

        guard type == Self.nxSystemDefined,
              let nsEvent = NSEvent(cgEvent: event),
              nsEvent.subtype.rawValue == Self.nxAuxControlSubtype else {
            return false
        }

        let keyCode = (nsEvent.data1 & 0xffff_0000) >> 16
        let keyState = (nsEvent.data1 & 0x0000_ff00) >> 8

        let isBrightnessDown: Bool
        switch keyCode {
        case Self.nxBrightnessDown:
            isBrightnessDown = true
        case Self.nxBrightnessUp:
            isBrightnessDown = false
        default:
            return false
        }

        let isDown: Bool
        switch keyState {
        case 0x0a:
            isDown = true
        case 0x0b:
            isDown = false
        default:
            return false
        }

        let fine = nsEvent.modifierFlags.contains([.option, .shift])
        let command = MonitorOSBrightnessCommand.make(
            down: isBrightnessDown,
            fine: fine
        )

        lastAuxTimestamp = ProcessInfo.processInfo.systemUptime
        let currentDisplayID = resolvedActiveDisplay(for: event)
        let consume = currentDisplayID == displayID

        print(
            "monitorOS Helper: brightness key path=NX command=\(command) " +
            "fine=\(fine) down=\(isDown) " +
            "currentDisplay=\(currentDisplayID.map { String($0) } ?? "none") " +
            "targetDisplay=\(displayID) consume=\(consume)"
        )

        if consume, isDown {
            sendBrightness(command)
        }
        return consume
    }

    private func handlePlainKeyEvent(
        type: CGEventType,
        event: CGEvent
    ) -> Bool {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let isDown = type == .keyDown

        let isBrightnessDown: Bool
        switch keyCode {
        case Self.standardF1, Self.brightnessKeycodeDown:
            isBrightnessDown = true
        case Self.standardF2, Self.brightnessKeycodeUp:
            isBrightnessDown = false
        default:
            return false
        }

        let flags = event.flags
        let fine =
            flags.contains(.maskAlternate)
            && flags.contains(.maskShift)
        let command = MonitorOSBrightnessCommand.make(
            down: isBrightnessDown,
            fine: fine
        )

        let currentDisplayID = resolvedActiveDisplay(for: event)
        guard currentDisplayID == displayID else {
            print(
                "monitorOS Helper: brightness key path=keycode code=\(keyCode) " +
                "currentDisplay=\(currentDisplayID.map { String($0) } ?? "none") " +
                "targetDisplay=\(displayID) consume=false"
            )
            return false
        }

        if keyCode == Self.standardF1 || keyCode == Self.standardF2 {
            print(
                "monitorOS Helper: brightness key path=F-key code=\(keyCode) " +
                "fine=\(fine) down=\(isDown) " +
                "targetDisplay=\(displayID) consume=true"
            )
            if isDown {
                sendBrightness(command)
            }
            return true
        }

        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastAuxTimestamp > Self.auxTwinWindow else {
            return false
        }

        print(
            "monitorOS Helper: brightness key path=keycode code=\(keyCode) " +
            "fine=\(fine) down=\(isDown) " +
            "targetDisplay=\(displayID) deferred=true"
        )

        Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.fallbackDelay)
            guard let self,
                  self.lastAuxTimestamp < now,
                  isDown,
                  self.activeDisplayID == self.displayID else {
                return
            }
            self.sendBrightness(command)
        }

        // macOS ignores this raw brightness-key leg; consuming it avoids
        // duplicate handling if there is no NX_SYSDEFINED twin.
        return true
    }

    private func sendBrightness(_ command: MonitorOSBrightnessCommand) {
        if let currentUnit = lastSliderFineUnit {
            let target = UInt8(
                min(
                    Int(monitorOSBrightnessFineSteps),
                    max(0, Int(currentUnit) + command.delta)
                )
            )
            lastSliderFineUnit = target
            displayedFineUnit = target
            cacheFineUnit(target)

            let optimisticValue =
                Float(target) / monitorOSBrightnessFineSteps
            hud.show(value: optimisticValue, on: displayID)

            guard target != currentUnit else {
                return
            }

            sender.set(fineUnit: target) { [weak self] applied in
                Task { @MainActor in
                    guard let self,
                          self.lastSliderFineUnit == target else {
                        return
                    }
                    let appliedUnit = self.fineUnit(from: applied)
                    self.lastSliderFineUnit = appliedUnit
                    self.displayedFineUnit = appliedUnit
                    self.cacheFineUnit(appliedUnit)
                    self.hud.update(value: applied)
                }
            }
            return
        }

        // We do not yet know the sink state. The HUD must still be immediate,
        // so animate from the last cached visual value while sending the
        // relative command. The sink reply then snaps the model to truth.
        displayedFineUnit = UInt8(
            min(
                Int(monitorOSBrightnessFineSteps),
                max(0, Int(displayedFineUnit) + command.delta)
            )
        )
        hud.show(
            value: Float(displayedFineUnit) / monitorOSBrightnessFineSteps,
            on: displayID
        )

        sender.send(command) { [weak self] value in
            Task { @MainActor in
                guard let self, self.lastSliderFineUnit == nil else {
                    return
                }
                let appliedUnit = self.fineUnit(from: value)
                self.lastSliderFineUnit = appliedUnit
                self.displayedFineUnit = appliedUnit
                self.cacheFineUnit(appliedUnit)
                self.hud.update(value: value)
            }
        }
    }

    private func setBrightnessFromSlider(_ value: Double) {
        let clamped = min(max(value, 0), 1)
        let fineUnit = UInt8(
            (clamped * Double(monitorOSBrightnessFineSteps)).rounded()
        )
        guard fineUnit != lastSliderFineUnit else {
            return
        }
        lastSliderFineUnit = fineUnit
        displayedFineUnit = fineUnit
        cacheFineUnit(fineUnit)

        sender.set(fineUnit: fineUnit) { [weak self] applied in
            Task { @MainActor in
                guard let self,
                      self.lastSliderFineUnit == fineUnit else {
                    return
                }
                let appliedUnit = self.fineUnit(from: applied)
                self.lastSliderFineUnit = appliedUnit
                self.displayedFineUnit = appliedUnit
                self.cacheFineUnit(appliedUnit)
                self.hud.update(value: applied)
            }
        }
    }

    private func fineUnit(from value: Float) -> UInt8 {
        UInt8(
            min(
                monitorOSBrightnessFineSteps,
                max(
                    0,
                    (value * monitorOSBrightnessFineSteps).rounded()
                )
            )
        )
    }

    private func cacheFineUnit(_ unit: UInt8) {
        UserDefaults.standard.set(
            Int(unit),
            forKey: Self.cachedFineUnitKey
        )
    }

    private func updateActiveDisplay(from event: CGEvent) {
        guard let resolved = displayIDForPoint(event.location) else {
            return
        }
        if activeDisplayID != resolved {
            activeDisplayID = resolved
            print(
                "monitorOS Helper: active display changed to id=\(resolved)"
            )
        }
    }

    private func resolvedActiveDisplay(
        for event: CGEvent
    ) -> CGDirectDisplayID? {
        if let activeDisplayID {
            return activeDisplayID
        }
        return displayIDForPoint(event.location)
    }

    private func displayIDForPoint(_ point: CGPoint) -> CGDirectDisplayID? {
        var displayID = CGDirectDisplayID()
        var count: UInt32 = 0
        let error = CGGetDisplaysWithPoint(
            point,
            1,
            &displayID,
            &count
        )
        guard error == .success, count == 1 else {
            return nil
        }
        return displayID
    }

    nonisolated static func selfTest() -> Bool {
        guard MonitorOSBrightnessCommand.make(
            down: true,
            fine: false
        ).rawValue == 1,
        MonitorOSBrightnessCommand.make(
            down: false,
            fine: false
        ).rawValue == 2,
        MonitorOSBrightnessCommand.make(
            down: true,
            fine: true
        ).rawValue == 3,
        MonitorOSBrightnessCommand.make(
            down: false,
            fine: true
        ).rawValue == 4 else {
            return false
        }

        do {
            let ipv6 = try MonitorOSControlEndpoint(
                videoTarget: "[fe80::1234%bridge0]:5202"
            )
            guard ipv6.host == "fe80::1234%bridge0",
                  ipv6.port == "5203" else {
                return false
            }
        } catch {
            return false
        }
        return true
    }
}

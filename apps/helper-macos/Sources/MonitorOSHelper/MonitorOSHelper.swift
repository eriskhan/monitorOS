import AppKit
import CoreGraphics
import CoreMedia
import CoreVideo
import Darwin
import Foundation
import Network
import ScreenCaptureKit
import MonitorOSCapture

private let helperDisplayVendorID: UInt32 = 0x0610
private let helperDisplayProductID: UInt32 = 0xAE11
private let reconnectFallbackDelay: TimeInterval = 0.5
private let eventFallbackDelay: TimeInterval = 5


private final class TimestampedStdio: @unchecked Sendable {
    private let readFD: Int32
    private let outputHandle: FileHandle
    private let queue = DispatchQueue(
        label: "org.monitoros.helper.timestamped-stdio"
    )
    private var pending = Data()
    private let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds,
        ]
        formatter.timeZone = .current
        return formatter
    }()

    private init(readFD: Int32, outputFD: Int32) {
        self.readFD = readFD
        outputHandle = FileHandle(
            fileDescriptor: outputFD,
            closeOnDealloc: true
        )
    }

    static func install() -> TimestampedStdio? {
        let savedStdout = Darwin.dup(STDOUT_FILENO)
        let savedStderr = Darwin.dup(STDERR_FILENO)
        guard savedStdout >= 0, savedStderr >= 0 else {
            if savedStdout >= 0 {
                Darwin.close(savedStdout)
            }
            if savedStderr >= 0 {
                Darwin.close(savedStderr)
            }
            return nil
        }

        var descriptors: [Int32] = [-1, -1]
        let pipeResult: Int32 = descriptors.withUnsafeMutableBufferPointer {
            guard let baseAddress = $0.baseAddress else {
                return Int32(-1)
            }
            return Darwin.pipe(baseAddress)
        }
        guard pipeResult == 0 else {
            Darwin.close(savedStdout)
            Darwin.close(savedStderr)
            return nil
        }

        guard Darwin.dup2(descriptors[1], STDOUT_FILENO) >= 0,
              Darwin.dup2(descriptors[1], STDERR_FILENO) >= 0 else {
            _ = Darwin.dup2(savedStdout, STDOUT_FILENO)
            _ = Darwin.dup2(savedStderr, STDERR_FILENO)
            Darwin.close(descriptors[0])
            Darwin.close(descriptors[1])
            Darwin.close(savedStdout)
            Darwin.close(savedStderr)
            return nil
        }

        Darwin.close(descriptors[1])
        Darwin.close(savedStdout)

        setvbuf(stdout, nil, _IOLBF, 0)
        setvbuf(stderr, nil, _IONBF, 0)

        let logger = TimestampedStdio(
            readFD: descriptors[0],
            outputFD: savedStderr
        )
        logger.start()
        return logger
    }

    private func start() {
        queue.async { [self] in
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)

            while true {
                let count = buffer.withUnsafeMutableBytes { bytes -> Int in
                    guard let base = bytes.baseAddress else {
                        return 0
                    }
                    return Darwin.read(readFD, base, bytes.count)
                }

                if count > 0 {
                    consume(Data(buffer[..<count]))
                    continue
                }
                if count == 0 {
                    break
                }
                if errno == EINTR {
                    continue
                }
                break
            }

            flushPending()
            Darwin.close(readFD)
            try? outputHandle.close()
        }
    }

    private func consume(_ data: Data) {
        pending.append(data)

        while let newline = pending.firstIndex(of: 0x0a) {
            let line = Data(pending[..<newline])
            writeLine(line)
            pending.removeSubrange(...newline)
        }
    }

    private func flushPending() {
        guard !pending.isEmpty else {
            return
        }
        writeLine(pending)
        pending.removeAll(keepingCapacity: false)
    }

    private func writeLine(_ line: Data) {
        let prefix = formatter.string(from: Date()) + " "
        try? outputHandle.write(contentsOf: Data(prefix.utf8))
        try? outputHandle.write(contentsOf: line)
        try? outputHandle.write(contentsOf: Data([0x0a]))
    }
}


private final class LifecycleChangeMonitor: @unchecked Sendable {
    private let networkMonitor = NWPathMonitor()
    private let networkQueue = DispatchQueue(
        label: "org.monitoros.helper.network"
    )
    private let condition = NSCondition()
    private var generation: UInt64 = 0
    private var screenSleepObserver: NSObjectProtocol?
    private var screenWakeObserver: NSObjectProtocol?
    private var screenParametersObserver: NSObjectProtocol?

    init() {
        networkMonitor.pathUpdateHandler = { [weak self] _ in
            self?.signal()
        }
        networkMonitor.start(queue: networkQueue)

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        screenSleepObserver = workspaceCenter.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.signal()
        }
        screenWakeObserver = workspaceCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.signal()
        }
        screenParametersObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.signal()
        }
    }

    deinit {
        networkMonitor.cancel()

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        if let screenSleepObserver {
            workspaceCenter.removeObserver(screenSleepObserver)
        }
        if let screenWakeObserver {
            workspaceCenter.removeObserver(screenWakeObserver)
        }
        if let screenParametersObserver {
            NotificationCenter.default.removeObserver(screenParametersObserver)
        }
    }

    func signal() {
        condition.lock()
        generation &+= 1
        condition.broadcast()
        condition.unlock()
    }

    func snapshot() -> UInt64 {
        condition.lock()
        defer { condition.unlock() }
        return generation
    }

    func waitForChange(
        after observedGeneration: UInt64,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)

        condition.lock()
        defer { condition.unlock() }
        while generation == observedGeneration {
            if !condition.wait(until: deadline) {
                return false
            }
        }
        return true
    }
}


private struct Options {
    var selfTest = false
    var showHelp = false

    static func parse(_ arguments: [String]) throws -> Options {
        var options = Options()

        for argument in arguments {
            switch argument {
            case "--self-test":
                options.selfTest = true
            case "-h", "--help":
                options.showHelp = true
            default:
                throw MonitorOSCaptureError(
                    "unknown argument: \(argument)"
                )
            }
        }

        return options
    }
}

private final class HelperVideoOutput:
    NSObject,
    SCStreamOutput,
    @unchecked Sendable
{
    private let transport: MonitorOSAsyncFrameTransport

    init(transport: MonitorOSAsyncFrameTransport) {
        self.transport = transport
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .screen,
              monitorOSFrameStatus(sampleBuffer) == .complete,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        else {
            return
        }

        let streamPTS =
            CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let hostPTS: CMTime
        if let synchronizationClock = stream.synchronizationClock {
            hostPTS = CMSyncConvertTime(
                streamPTS,
                from: synchronizationClock,
                to: CMClockGetHostTimeClock()
            )
        } else {
            // ScreenCaptureKit normally supplies its synchronization clock.
            // Keep the legacy timestamp as a degraded fallback so video still
            // works if the clock is temporarily unavailable during teardown.
            hostPTS = streamPTS
        }

        let seconds = CMTimeGetSeconds(hostPTS)
        let ptsNanos = seconds.isFinite && seconds >= 0
            ? UInt64((seconds * 1_000_000_000).rounded())
            : 0

        let damageRects = monitorOSFrameDirtyRects(sampleBuffer)
        transport.submit(
            pixelBuffer: pixelBuffer,
            ptsNanos: ptsNanos,
            damageRects: damageRects
        )
    }

}

private final class HelperStreamDelegate:
    NSObject,
    SCStreamDelegate,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var stoppedError: String?

    var error: String? {
        lock.lock()
        defer { lock.unlock() }
        return stoppedError
    }

    func stream(
        _ stream: SCStream,
        didStopWithError error: Error
    ) {
        lock.lock()
        stoppedError = String(describing: error)
        lock.unlock()
    }
}

private func helperDisplayConfiguration() -> MonitorOSVirtualDisplayConfiguration {
    MonitorOSVirtualDisplayConfiguration(
        name: "iMac 5K",
        pixelsPerInch: 245,
        vendorID: helperDisplayVendorID,
        productID: helperDisplayProductID,
        serialNumber: 1
    )
}


@MainActor
private final class HelperDisplayController {
    private var display: MonitorOSVirtualDisplay?

    var retainedDisplayIsSleepingOrInactive: Bool {
        guard let display else {
            return false
        }

        return CGDisplayIsOnline(display.displayID) == 1
            && (
                CGDisplayIsActive(display.displayID) != 1
                || CGDisplayIsAsleep(display.displayID) == 1
            )
    }

    func releaseRetainedDisplay(reason: String) {
        guard let display else {
            return
        }

        print(
            "monitorOS Helper: releasing virtual display " +
            "id=\(display.displayID): \(reason)"
        )
        self.display = nil
    }

    func displayForSession() async throws -> MonitorOSVirtualDisplay {
        if let display {
            if CGDisplayIsOnline(display.displayID) == 1 {
                if CGDisplayIsActive(display.displayID) == 1,
                   CGDisplayIsAsleep(display.displayID) != 1 {
                    print(
                        "monitorOS Helper: reusing virtual display " +
                        "id=\(display.displayID)"
                    )
                    return display
                }

                throw MonitorOSCaptureError(
                    "retained virtual display id=\(display.displayID) " +
                    "is asleep/inactive"
                )
            }

            print(
                "monitorOS Helper: retained virtual display " +
                "id=\(display.displayID) went offline; waiting for return"
            )
            do {
                try await display.waitUntilReady(
                    requireConfiguredLogicalSize: false
                )
                print(
                    "monitorOS Helper: retained virtual display " +
                    "id=\(display.displayID) returned; reusing it"
                )
                return display
            } catch {
                print(
                    "monitorOS Helper: retained virtual display " +
                    "id=\(display.displayID) did not return; recreating"
                )
                self.display = nil
            }
        }

        let display = try MonitorOSVirtualDisplay(
            configuration: helperDisplayConfiguration()
        )
        print("monitorOS Helper: virtual display id=\(display.displayID)")
        try await display.waitUntilReady(
            requireConfiguredLogicalSize: false
        )
        await MonitorOSDisplayColorProfile.initializeDisplayP3IfNeeded(
            displayID: display.displayID
        )
        let bounds = CGDisplayBounds(display.displayID)
        print(
            "monitorOS Helper: virtual display ready at " +
            "\(Int(bounds.width.rounded()))x" +
            "\(Int(bounds.height.rounded())) logical"
        )
        self.display = display
        return display
    }
}

@MainActor
private func runSession(
    target: String,
    displayController: HelperDisplayController
) async throws {
    let display = try await displayController.displayForSession()

    print("monitorOS Helper: connecting to \(target)")
    let transport = try MonitorOSAsyncFrameTransport(target: target)
    print("monitorOS Helper: transport connected")

    let audioRelay: MonitorOSAudioRelay?
    do {
        audioRelay = try MonitorOSAudioRelay(videoTarget: target)
    } catch {
        audioRelay = nil
        fputs(
            "monitorOS Helper: iMac Speakers unavailable: \(error)\n",
            stderr
        )
    }
    defer {
        audioRelay?.stop()
    }

    let brightnessHotkeys: MonitorOSBrightnessHotkeys?
    do {
        brightnessHotkeys = try MonitorOSBrightnessHotkeys(
            displayID: display.displayID,
            videoTarget: target
        )
    } catch {
        brightnessHotkeys = nil
        fputs(
            "monitorOS Helper: brightness hotkeys unavailable: \(error)\n",
            stderr
        )
    }
    defer {
        brightnessHotkeys?.stop()
    }

    let scDisplay = try await monitorOSFindScreenCaptureDisplay(
        displayID: display.displayID
    )
    print(
        "monitorOS Helper: ScreenCaptureKit display " +
        "id=\(scDisplay.displayID) \(scDisplay.width)x\(scDisplay.height)"
    )

    let filter = SCContentFilter(
        display: scDisplay,
        excludingWindows: []
    )

    let configuration = SCStreamConfiguration()
    configuration.width = 5120
    configuration.height = 2880
    configuration.pixelFormat = kCVPixelFormatType_32BGRA
    configuration.minimumFrameInterval = CMTime(value: 1, timescale: 120)
    configuration.queueDepth = 3
    configuration.showsCursor = true
    configuration.capturesAudio = false

    let output = HelperVideoOutput(transport: transport)
    let callbackQueue = DispatchQueue(
        label: "org.monitoros.helper.video",
        qos: .userInteractive
    )
    let streamDelegate = HelperStreamDelegate()
    let stream = SCStream(
        filter: filter,
        configuration: configuration,
        delegate: streamDelegate
    )
    try stream.addStreamOutput(
        output,
        type: .screen,
        sampleHandlerQueue: callbackQueue
    )

    try await stream.startCapture()
    print(
        "monitorOS Helper: streaming packed 4:2:2/yuvf with cursor enabled"
    )

    var sessionEndReason: String?
    while transport.error == nil {
        if let streamError = streamDelegate.error {
            sessionEndReason = "ScreenCaptureKit stopped: \(streamError)"
            break
        }
        if CGDisplayIsOnline(display.displayID) != 1 {
            sessionEndReason = "virtual display terminated by WindowServer"
            break
        }
        try await Task.sleep(for: .milliseconds(250))
    }

    let sessionError =
        transport.error
        ?? sessionEndReason
        ?? "transport stopped"
    do {
        try await stream.stopCapture()
    } catch {
        fputs(
            "monitorOS Helper: capture stop after session end: \(error)\n",
            stderr
        )
    }

    let snapshot = transport.finish()
    print(
        "monitorOS Helper: session ended; submitted=\(snapshot.submittedFrames) " +
        "sent=\(snapshot.sentFrames) replaced=\(snapshot.replacedFrames) " +
        "skipped=\(snapshot.skippedFrames)"
    )
    if snapshot.refinedFrames > 0 {
        let refinedFramePixels =
            Double(snapshot.refinedFrames) * 5120.0 * 2880.0
        let candidatePercent =
            Double(snapshot.refinementCandidatePixels) * 100.0
            / refinedFramePixels
        let tileCoveragePercent =
            Double(snapshot.refinementTileCoveragePixels) * 100.0
            / refinedFramePixels
        let refinedPairs =
            Double(snapshot.refinedFrames)
                * 5120.0 * 2880.0 / 2.0
        let pairChangedPercent =
            Double(snapshot.refinementChangedPairs) * 100.0
            / refinedPairs
        let refinedWireBytes =
            Double(snapshot.refinedFrames)
                * 5120.0 * 2880.0 * 2.0
        let changedWirePercent =
            Double(snapshot.refinementChangedWireBytes) * 100.0
            / refinedWireBytes
        print(
            String(
                format:
                    "monitorOS Helper: content damage refinement: " +
                    "frames=%d content-skipped=%d " +
                    "candidate=%.1f%% tile-coverage=%.1f%% " +
                    "pair-changed=%.3f%% wire-changed=%.3f%%",
                snapshot.refinedFrames,
                snapshot.contentSkippedFrames,
                candidatePercent,
                tileCoveragePercent,
                pairChangedPercent,
                changedWirePercent
            )
        )
    }

    throw MonitorOSCaptureError(sessionError)
}

private func usage() {
    print(
        """
        monitoros-helper

          default              discover _monitoros._tcp over Bonjour
          --self-test          validate helper invariants without capture
        """
    )
}

private func selfTest(_ options: Options) -> Bool {
    let displayConfiguration = helperDisplayConfiguration()
    guard reconnectFallbackDelay == 0.5,
          eventFallbackDelay == 5,
          displayConfiguration.vendorID == helperDisplayVendorID,
          displayConfiguration.productID == helperDisplayProductID,
          displayConfiguration.logicalWidth == 2560,
          displayConfiguration.logicalHeight == 1440,
          MonitorOSBrightnessHotkeys.selfTest(),
          MonitorOSDisplayColorProfile.selfTest(),
          MonitorOSAudioRelay.selfTest(),
          options.selfTest
    else {
        return false
    }

    do {
        var address = sockaddr_in6()
        address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        address.sin6_family = sa_family_t(AF_INET6)
        guard "fe80::1234".withCString({
            inet_pton(AF_INET6, $0, &address.sin6_addr)
        }) == 1 else {
            return false
        }
        let scopedTarget = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(
                to: sockaddr.self,
                capacity: 1
            ) { socketAddress in
                MonitorOSSinkDiscovery.scopedIPv6Target(
                    address: socketAddress,
                    interfaceIndex: 1,
                    port: 5202
                )
            }
        }
        guard let scopedTarget,
              scopedTarget.hasPrefix("[fe80::1234%"),
              scopedTarget.hasSuffix("]:5202") else {
            return false
        }

        guard MonitorOSSinkDiscovery.isMonitorLinkInterfaceName("bridge0"),
              !MonitorOSSinkDiscovery.isMonitorLinkInterfaceName("en0"),
              !MonitorOSSinkDiscovery.isMonitorLinkInterfaceName("bridge100")
        else {
            return false
        }
    } catch {
        return false
    }

    print("monitorOS Helper self-test passed")
    return true
}

@main
struct MonitorOSHelper {
    @MainActor
    static func main() {
        let options: Options

        do {
            options = try Options.parse(
                Array(CommandLine.arguments.dropFirst())
            )
        } catch {
            fputs("monitorOS Helper: \(error)\n", stderr)
            usage()
            exit(64)
        }

        if options.showHelp {
            usage()
            return
        }

        if options.selfTest {
            exit(selfTest(options) ? 0 : 1)
        }

        let timestampedStdio = TimestampedStdio.install()

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        // DisplayPane relies on NSApplication.run(), not merely
        // finishLaunching().  The real AppKit event loop is required for
        // NSScreen to learn about a CGVirtualDisplay created after launch and
        // for nonactivating NSPanel hover/mouse tracking to work.
        let runtime = Task { @MainActor in
            await run()
        }

        app.run()
        withExtendedLifetime(timestampedStdio) {}
        runtime.cancel()
    }

    @MainActor
    private static func run() async {
        guard CGPreflightScreenCaptureAccess()
                || CGRequestScreenCaptureAccess() else {
            fputs(
                """
                monitorOS Helper requires Screen & System Audio Recording access.
                Enable it in System Settings > Privacy & Security, then relaunch
                the Helper.

                """,
                stderr
            )
            exit(2)
        }

        let lifecycleChanges = LifecycleChangeMonitor()
        let displayController = HelperDisplayController()
        let discovery: MonitorOSSinkDiscovery
        do {
            discovery = try MonitorOSSinkDiscovery(
                onChange: {
                    lifecycleChanges.signal()
                }
            )
            print(
                "monitorOS Helper: browsing Bonjour " +
                "\(MonitorOSSinkDiscovery.serviceType)"
            )
        } catch {
            fputs(
                "monitorOS Helper: discovery startup failed: \(error)\n",
                stderr
            )
            exit(3)
        }

        while true {
            var snapshot = discovery.snapshot()
            while snapshot.target == nil {
                let observedLifecycle = lifecycleChanges.snapshot()
                snapshot = discovery.snapshot()
                if snapshot.target != nil {
                    break
                }

                displayController.releaseRetainedDisplay(
                    reason: "monitorOS sink unavailable"
                )

                if let error = snapshot.error {
                    fputs(
                        "monitorOS Helper: discovery: \(error)\n",
                        stderr
                    )
                }

                let changed = await Task.detached {
                    lifecycleChanges.waitForChange(
                        after: observedLifecycle,
                        timeout: eventFallbackDelay
                    )
                }.value
                snapshot = discovery.snapshot()
                if !changed,
                   snapshot.target == nil {
                    discovery.retryResolution()
                }
            }

            let target = snapshot.target!
            print("monitorOS Helper: discovered sink \(target)")

            let displayWaitGeneration = lifecycleChanges.snapshot()
            if displayController.retainedDisplayIsSleepingOrInactive {
                print(
                    "monitorOS Helper: retained virtual display is asleep; " +
                    "waiting for lifecycle change"
                )
                await Task.detached {
                    _ = lifecycleChanges.waitForChange(
                        after: displayWaitGeneration,
                        timeout: eventFallbackDelay
                    )
                }.value
                continue
            }

            let sessionGeneration = lifecycleChanges.snapshot()
            do {
                try await runSession(
                    target: target,
                    displayController: displayController
                )
            } catch {
                fputs(
                    "monitorOS Helper: session failed: \(error)\n",
                    stderr
                )

                if displayController.retainedDisplayIsSleepingOrInactive {
                    print(
                        "monitorOS Helper: retained virtual display is asleep; " +
                        "waiting for lifecycle change"
                    )
                    continue
                }

                print(
                    "monitorOS Helper: waiting for lifecycle change " +
                    "(\(Int(reconnectFallbackDelay * 1000))ms fallback)"
                )
                await Task.detached {
                    _ = lifecycleChanges.waitForChange(
                        after: sessionGeneration,
                        timeout: reconnectFallbackDelay
                    )
                }.value
            }
        }

    }
}

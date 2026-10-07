import AppKit
import CoreGraphics
import Foundation
import ServiceManagement

private let controllerBundleID = "com.monitorOS.controller"
private let helperRestartDelay: TimeInterval = 2
private let permissionPollInterval: TimeInterval = 2

private enum ManagementAction {
    case register
    case unregister
    case status
}

private enum AnalyticsChoice: String {
    case enabled
    case disabled
}

private struct ControllerPaths {
    let supportDirectory: URL
    let legacyHelperURL: URL
    let helperURL: URL
    let logDirectory: URL
    let controllerLogURL: URL
    let helperLogURL: URL
    let observationDirectory: URL
    let analyticsChoiceURL: URL

    static func currentUser() -> ControllerPaths {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let support = home
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent("monitorOS", isDirectory: true)
        let logs = home
            .appendingPathComponent("Library/Logs", isDirectory: true)
            .appendingPathComponent("monitorOS", isDirectory: true)

        return ControllerPaths(
            supportDirectory: support,
            legacyHelperURL: support
                .appendingPathComponent("bin", isDirectory: true)
                .appendingPathComponent("monitoros-helper"),
            helperURL: Bundle.main.bundleURL
                .appendingPathComponent("Contents/Helpers", isDirectory: true)
                .appendingPathComponent("monitoros-helper"),
            logDirectory: logs,
            controllerLogURL: logs.appendingPathComponent("controller.log"),
            helperLogURL: logs.appendingPathComponent("helper.log"),
            observationDirectory: home.appendingPathComponent(
                ".monitoros-observation",
                isDirectory: true
            ),
            analyticsChoiceURL: support.appendingPathComponent("analytics-choice.txt")
        )
    }
}

private func statusName(_ status: SMAppService.Status) -> String {
    switch status {
    case .notRegistered:
        return "not-registered"
    case .enabled:
        return "enabled"
    case .requiresApproval:
        return "requires-approval"
    case .notFound:
        return "not-found"
    @unknown default:
        return "unknown"
    }
}

private func requirePackagedApplication() throws {
    guard Bundle.main.bundleIdentifier == controllerBundleID,
          Bundle.main.bundleURL.pathExtension == "app" else {
        throw NSError(
            domain: controllerBundleID,
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "login-item management requires the packaged monitorOS.app"
            ]
        )
    }
}

private func performManagementAction(_ action: ManagementAction) throws {
    try requirePackagedApplication()
    let service = SMAppService.mainApp

    switch action {
    case .register:
        switch service.status {
        case .enabled:
            break
        case .notRegistered, .notFound:
            try service.register()
        case .requiresApproval:
            SMAppService.openSystemSettingsLoginItems()
        @unknown default:
            try service.register()
        }

        print("monitorOS controller: login-item status=\(statusName(service.status))")
        if service.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        }

    case .unregister:
        switch service.status {
        case .notRegistered, .notFound:
            break
        case .enabled, .requiresApproval:
            try service.unregister()
        @unknown default:
            try service.unregister()
        }
        print("monitorOS controller: login item unregistered")

    case .status:
        print("monitorOS controller: login-item status=\(statusName(service.status))")
    }
}

private final class ControllerDelegate: NSObject, NSApplicationDelegate {
    private let paths = ControllerPaths.currentUser()
    private var helperProcess: Process?
    private var helperLogHandle: FileHandle?
    private var restartWorkItem: DispatchWorkItem?
    private var permissionTimer: Timer?
    private var requestedPermission = false
    private var showedPermissionHelp = false
    private var terminating = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        configureAnalyticsIfNeeded()
        removeLegacyHelper()

        do {
            try FileManager.default.createDirectory(
                at: paths.logDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            // Logging is best effort; helper supervision must still work.
        }

        log("controller started")

        do {
            try performManagementAction(.register)
        } catch {
            log("login-item registration failed: \(error)")
        }

        evaluateScreenRecordingPermission()
    }

    func applicationWillTerminate(_ notification: Notification) {
        terminating = true
        permissionTimer?.invalidate()
        permissionTimer = nil
        restartWorkItem?.cancel()
        restartWorkItem = nil

        if let process = helperProcess, process.isRunning {
            log("terminating helper pid=\(process.processIdentifier)")
            process.terminate()
        }
        helperLogHandle?.closeFile()
        helperLogHandle = nil
    }

    private func configureAnalyticsIfNeeded() {
        let fm = FileManager.default

        do {
            if let choice = try readAnalyticsChoice() {
                try applyAnalyticsChoice(choice)
                return
            }

            if fm.fileExists(atPath: paths.observationDirectory.path) {
                try writeAnalyticsChoice(.enabled)
                return
            }

            let hasLegacyInstall =
                fm.fileExists(atPath: paths.legacyHelperURL.path) ||
                fm.fileExists(atPath: paths.supportDirectory.path) ||
                fm.fileExists(atPath: paths.logDirectory.path)

            if hasLegacyInstall {
                try writeAnalyticsChoice(.disabled)
                try? fm.removeItem(at: paths.observationDirectory)
                return
            }

            let choice = promptForAnalytics()
            try writeAnalyticsChoice(choice)
            try applyAnalyticsChoice(choice)
        } catch {
            log("analytics configuration failed: \(error)")
        }
    }

    private func readAnalyticsChoice() throws -> AnalyticsChoice? {
        guard FileManager.default.fileExists(atPath: paths.analyticsChoiceURL.path) else {
            return nil
        }

        let raw = try String(
            contentsOf: paths.analyticsChoiceURL,
            encoding: .utf8
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        return AnalyticsChoice(rawValue: raw)
    }

    private func writeAnalyticsChoice(_ choice: AnalyticsChoice) throws {
        try FileManager.default.createDirectory(
            at: paths.supportDirectory,
            withIntermediateDirectories: true
        )
        try (choice.rawValue + "\n").write(
            to: paths.analyticsChoiceURL,
            atomically: true,
            encoding: .utf8
        )
    }

    private func applyAnalyticsChoice(_ choice: AnalyticsChoice) throws {
        switch choice {
        case .enabled:
            try ensureAnalyticsObservation()
        case .disabled:
            try? FileManager.default.removeItem(at: paths.observationDirectory)
        }
    }

    private func ensureAnalyticsObservation() throws {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: paths.observationDirectory.path) else {
            return
        }

        try fm.createDirectory(
            at: paths.observationDirectory,
            withIntermediateDirectories: true
        )

        try "\(fileSize(paths.helperLogURL))\n".write(
            to: paths.observationDirectory.appendingPathComponent("helper.start"),
            atomically: true,
            encoding: .utf8
        )
        try "\(fileSize(paths.controllerLogURL))\n".write(
            to: paths.observationDirectory.appendingPathComponent("controller.start"),
            atomically: true,
            encoding: .utf8
        )

        let formatter = ISO8601DateFormatter()
        try (formatter.string(from: Date()) + "\n").write(
            to: paths.observationDirectory.appendingPathComponent("start.txt"),
            atomically: true,
            encoding: .utf8
        )

        let revision: String
        if let revisionURL = Bundle.main.url(
            forResource: "git-head",
            withExtension: "txt"
        ) {
            let rawRevision = try? String(
                contentsOf: revisionURL,
                encoding: .utf8
            )
            revision = rawRevision?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
        } else {
            revision = "unknown"
        }

        try (revision + "\n").write(
            to: paths.observationDirectory.appendingPathComponent("git-head.txt"),
            atomically: true,
            encoding: .utf8
        )
    }

    private func promptForAnalytics() -> AnalyticsChoice {
        NSApp.activate(ignoringOtherApps: true)

        let checkbox = NSButton(
            checkboxWithTitle: "Collect analytics",
            target: nil,
            action: nil
        )
        checkbox.state = .off

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Welcome to monitorOS"
        alert.informativeText =
            "Optionally keep local performance-log markers for later diagnostic collection. " +
            "Nothing is uploaded automatically."
        alert.accessoryView = checkbox
        alert.addButton(withTitle: "Continue")
        alert.runModal()

        return checkbox.state == .on ? .enabled : .disabled
    }

    private func fileSize(_ url: URL) -> UInt64 {
        guard let attributes = try? FileManager.default.attributesOfItem(
            atPath: url.path
        ),
        let size = attributes[.size] as? NSNumber else {
            return 0
        }

        return size.uint64Value
    }

    private func removeLegacyHelper() {
        guard FileManager.default.fileExists(atPath: paths.legacyHelperURL.path) else {
            return
        }

        do {
            try FileManager.default.removeItem(at: paths.legacyHelperURL)
        } catch {
            log("could not remove legacy helper: \(error)")
        }
    }

    private func evaluateScreenRecordingPermission() {
        if CGPreflightScreenCaptureAccess() {
            permissionTimer?.invalidate()
            permissionTimer = nil
            startHelperIfNeeded()
            return
        }

        if !requestedPermission {
            requestedPermission = true
            log("requesting Screen Recording permission")
            if CGRequestScreenCaptureAccess() {
                startHelperIfNeeded()
                return
            }
        }

        if !showedPermissionHelp {
            showedPermissionHelp = true
            showPermissionHelp()
        }

        if permissionTimer == nil {
            permissionTimer = Timer.scheduledTimer(
                withTimeInterval: permissionPollInterval,
                repeats: true
            ) { [weak self] _ in
                self?.evaluateScreenRecordingPermission()
            }
        }
    }

    private func showPermissionHelp() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Allow Screen Recording for monitorOS"
        alert.informativeText =
            "monitorOS needs Screen Recording access to send the virtual display to your iMac. " +
            "monitorOS stays open quietly and will start streaming as soon as permission is available."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")

        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(
               string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
           ) {
            NSWorkspace.shared.open(url)
        }
    }

    private func startHelperIfNeeded() {
        guard !terminating else {
            return
        }
        if let process = helperProcess, process.isRunning {
            return
        }

        guard FileManager.default.isExecutableFile(atPath: paths.helperURL.path) else {
            log("helper is missing from monitorOS.app at \(paths.helperURL.path); retrying")
            scheduleHelperRestart(after: 5)
            return
        }

        do {
            try FileManager.default.createDirectory(
                at: paths.logDirectory,
                withIntermediateDirectories: true
            )
            if !FileManager.default.fileExists(atPath: paths.helperLogURL.path) {
                FileManager.default.createFile(
                    atPath: paths.helperLogURL.path,
                    contents: nil
                )
            }

            let logHandle = try FileHandle(forWritingTo: paths.helperLogURL)
            try logHandle.seekToEnd()

            let process = Process()
            process.executableURL = paths.helperURL
            process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
            process.standardOutput = logHandle
            process.standardError = logHandle
            process.terminationHandler = { [weak self, weak process] finished in
                DispatchQueue.main.async {
                    guard let self else {
                        return
                    }
                    if let process, self.helperProcess === process {
                        self.helperProcess = nil
                    }
                    self.helperLogHandle?.closeFile()
                    self.helperLogHandle = nil
                    self.log(
                        "helper exited status=\(finished.terminationStatus) " +
                        "reason=\(finished.terminationReason.rawValue)"
                    )
                    if !self.terminating {
                        self.scheduleHelperRestart(after: helperRestartDelay)
                    }
                }
            }

            try process.run()
            helperProcess = process
            helperLogHandle = logHandle
            log("helper started pid=\(process.processIdentifier)")
        } catch {
            helperLogHandle?.closeFile()
            helperLogHandle = nil
            helperProcess = nil
            log("helper launch failed: \(error)")
            scheduleHelperRestart(after: helperRestartDelay)
        }
    }

    private func scheduleHelperRestart(after delay: TimeInterval) {
        guard !terminating else {
            return
        }
        restartWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.restartWorkItem = nil
            self?.startHelperIfNeeded()
        }
        restartWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func log(_ message: String) {
        let formatter = ISO8601DateFormatter()
        let line = "\(formatter.string(from: Date())) \(message)\n"
        let data = Data(line.utf8)

        do {
            try FileManager.default.createDirectory(
                at: paths.logDirectory,
                withIntermediateDirectories: true
            )
            if !FileManager.default.fileExists(atPath: paths.controllerLogURL.path) {
                FileManager.default.createFile(
                    atPath: paths.controllerLogURL.path,
                    contents: nil
                )
            }
            let handle = try FileHandle(forWritingTo: paths.controllerLogURL)
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.close()
        } catch {
            // Nothing else depends on logging.
        }
    }
}

@main
private struct MonitorOSController {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())

        if arguments.count == 1 {
            let action: ManagementAction?
            switch arguments[0] {
            case "--register-login-item":
                action = .register
            case "--unregister-login-item":
                action = .unregister
            case "--login-item-status":
                action = .status
            default:
                action = nil
            }

            if let action {
                do {
                    try performManagementAction(action)
                    exit(EXIT_SUCCESS)
                } catch {
                    fputs("monitorOS controller: \(error)\n", stderr)
                    exit(EXIT_FAILURE)
                }
            }
        }

        if !arguments.isEmpty {
            fputs(
                "usage: monitoros-controller [--register-login-item|--unregister-login-item|--login-item-status]\n",
                stderr
            )
            exit(64)
        }

        let application = NSApplication.shared
        let delegate = ControllerDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
    }
}

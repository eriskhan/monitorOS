import AppKit
import SwiftUI

private let controllerID = "com.monitorOS.controller"
private let controllerPath = "/Applications/monitorOS.app"
private let legacyControllerPath = "/Applications/monitorOS controller.app"
private let utilitiesPath = "/Applications/Utilities/monitorOS"
private let audioDriverPath = "/Library/Audio/Plug-Ins/HAL/monitorOSAudio.driver"
private let packageID = "com.monitorOS.pkg"

@MainActor
private final class Model: ObservableObject {
    @Published var status = ""
    @Published var busy = false
    @Published var done = false
    @Published var failed = false
    @Published var confirmRemove = false

    func run() {
        confirmRemove = true
    }

    func remove() {
        confirmRemove = false
        busy = true
        failed = false

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try Uninstaller().remove(progress: self.update)
                Task { @MainActor in
                    self.busy = false
                    self.done = true
                    self.status = "monitorOS has been removed."
                }
            } catch {
                Task { @MainActor in
                    self.busy = false
                    self.failed = true
                    self.status = error.localizedDescription
                }
            }
        }
    }

    private func update(_ status: String) {
        Task { @MainActor in
            self.status = status
        }
    }
}

private struct Uninstaller {
    private let fm = FileManager.default

    private var support: URL {
        fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/monitorOS")
    }

    private var logs: URL {
        fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/monitorOS")
    }

    private var observation: URL {
        fm.homeDirectoryForCurrentUser
            .appendingPathComponent(".monitoros-observation")
    }

    func remove(progress: @escaping (String) -> Void) throws {
        progress("Disabling monitorOS at login…")
        let executable = URL(
            fileURLWithPath: controllerPath + "/Contents/MacOS/monitoros-controller"
        )
        if fm.isExecutableFile(atPath: executable.path) {
            try? run(executable, ["--unregister-login-item"])
        }

        stopProcesses()

        progress("Removing user data…")
        try? fm.removeItem(at: support)
        try? fm.removeItem(at: logs)
        try? fm.removeItem(at: observation)
        try? run(
            URL(fileURLWithPath: "/usr/bin/tccutil"),
            ["reset", "ScreenCapture", controllerID]
        )

        progress("Removing monitorOS…")
        try privileged(
            [
                "set -eu",
                "/bin/rm -rf \(q(controllerPath))",
                "/bin/rm -rf \(q(legacyControllerPath))",
                "/bin/rm -rf \(q(utilitiesPath))",
                "/bin/rm -rf \(q(audioDriverPath))",
                "/usr/sbin/pkgutil --forget \(q(packageID)) >/dev/null 2>&1 || true",
                "/usr/bin/killall coreaudiod 2>/dev/null || true",
            ].joined(separator: "\n")
        )
    }

    private func stopProcesses() {
        for app in NSRunningApplication.runningApplications(
            withBundleIdentifier: controllerID
        ) {
            app.terminate()
        }
        try? run(
            URL(fileURLWithPath: "/usr/bin/pkill"),
            ["-TERM", "-x", "monitoros-helper"]
        )
        Thread.sleep(forTimeInterval: 0.4)
    }

    private func run(_ executable: URL, _ arguments: [String]) throws {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            throw error(
                String(data: data, encoding: .utf8) ?? "Command failed."
            )
        }
    }

    private func privileged(_ body: String) throws {
        let temporary = fm.temporaryDirectory.appendingPathComponent(
            "monitoros-\(UUID().uuidString).sh"
        )
        defer { try? fm.removeItem(at: temporary) }

        try ("#!/bin/sh\n" + body + "\n").write(
            to: temporary,
            atomically: true,
            encoding: .utf8
        )
        try fm.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: temporary.path
        )

        let command = "/bin/sh \(q(temporary.path))"
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        var info: NSDictionary?
        NSAppleScript(
            source: "do shell script \"\(escaped)\" with administrator privileges"
        )?.executeAndReturnError(&info)

        if let info {
            throw error(
                info["NSAppleScriptErrorMessage"] as? String ??
                    "Administrator authorization failed."
            )
        }
    }

    private func q(_ string: String) -> String {
        "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func error(_ message: String) -> NSError {
        NSError(
            domain: "com.monitorOS.uninstaller",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}

private struct UninstallerView: View {
    @ObservedObject var model: Model

    var body: some View {
        VStack(spacing: 20) {
            Image(nsImage: artwork)
                .resizable()
                .scaledToFit()
                .frame(width: 110, height: 90)

            Text("Remove monitorOS")
                .font(.title2.bold())

            if model.busy {
                ProgressView()
                Text(model.status)
                    .foregroundStyle(.secondary)
            } else if model.done {
                Text(model.status)
                Button("Done") {
                    NSApp.terminate(nil)
                }
                .keyboardShortcut(.defaultAction)
            } else if model.failed {
                Text(model.status)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Button("Close") {
                    NSApp.terminate(nil)
                }
            } else {
                Text(
                    "Removes monitorOS, iMac Speakers audio device, login item, logs and Screen Recording entry."
                )
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

                Button("Remove monitorOS") {
                    model.run()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(32)
        .frame(width: 480, height: 360)
        .confirmationDialog(
            "Remove monitorOS from this Mac?",
            isPresented: $model.confirmRemove
        ) {
            Button("Remove monitorOS", role: .destructive) {
                model.remove()
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var artwork: NSImage {
        if let url = Bundle.main.resourceURL?.appendingPathComponent("imac.svg"),
           let image = NSImage(contentsOf: url) {
            return image
        }

        return NSImage(
            systemSymbolName: "display",
            accessibilityDescription: nil
        ) ?? NSImage()
    }
}

@main
private struct MonitorOSUninstallerApp: App {
    @StateObject private var model = Model()

    var body: some Scene {
        WindowGroup {
            UninstallerView(model: model)
        }
    }
}

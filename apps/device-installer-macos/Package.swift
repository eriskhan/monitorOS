// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MonitorOSUninstaller",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "monitoros-uninstaller",
            targets: ["MonitorOSUninstaller"]
        )
    ],
    targets: [
        .executableTarget(
            name: "MonitorOSUninstaller",
            path: "Sources/MonitorOSUninstaller",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI")
            ]
        )
    ]
)

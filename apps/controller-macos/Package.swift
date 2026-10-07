// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MonitorOSController",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "monitoros-controller",
            targets: ["MonitorOSController"]
        )
    ],
    targets: [
        .executableTarget(
            name: "MonitorOSController",
            path: "Sources/MonitorOSController",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("ServiceManagement")
            ]
        )
    ]
)

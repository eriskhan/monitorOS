// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MonitorOSHelper",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "monitoros-helper",
            targets: ["MonitorOSHelper"]
        )
    ],
    targets: [
        .target(
            name: "CGVirtualDisplayPrivate",
            path: "Sources/CGVirtualDisplayPrivate",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("Cocoa"),
                .linkedFramework("CoreGraphics")
            ]
        ),
        .target(
            name: "MonitorOSCapture",
            dependencies: ["CGVirtualDisplayPrivate"],
            path: "Sources/MonitorOSCapture",
            linkerSettings: [
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("Metal"),
                .linkedFramework("ScreenCaptureKit")
            ]
        ),
        .executableTarget(
            name: "MonitorOSHelper",
            dependencies: ["MonitorOSCapture"],
            path: "Sources/MonitorOSHelper",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("ColorSync"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("Network"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("SwiftUI")
            ]
        ),
        .testTarget(
            name: "MonitorOSCaptureTests",
            dependencies: ["MonitorOSCapture"]
        )
    ]
)

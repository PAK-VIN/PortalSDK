// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PortalSDK",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "PortalSDK", targets: ["PortalSDK"])
    ],
    targets: [
        .target(
            name: "PortalSDK",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "PortalSDKTests",
            dependencies: ["PortalSDK"]
        )
    ]
)

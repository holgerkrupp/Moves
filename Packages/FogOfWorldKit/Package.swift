// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FogOfWorldKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(name: "FogOfWorldKit", targets: ["FogOfWorldKit"])
    ],
    targets: [
        .target(name: "FogOfWorldKit"),
        .testTarget(name: "FogOfWorldKitTests", dependencies: ["FogOfWorldKit"])
    ]
)

// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RouteFileKit",
    platforms: [
        .iOS(.v18),
        .macOS(.v15)
    ],
    products: [
        .library(name: "RouteFileKit", targets: ["RouteFileKit"]),
        .library(name: "RoutePreviewKit", targets: ["RoutePreviewKit"])
    ],
    targets: [
        .target(name: "RouteFileKit"),
        .target(name: "RoutePreviewKit", dependencies: ["RouteFileKit"]),
        .testTarget(name: "RouteFileKitTests", dependencies: ["RouteFileKit", "RoutePreviewKit"])
    ]
)

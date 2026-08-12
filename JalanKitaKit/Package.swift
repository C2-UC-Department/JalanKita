// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "JalanKitaKit",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
    ],
    products: [
        .library(name: "JalanKitaKit", targets: ["JalanKitaKit"]),
    ],
    targets: [
        .target(name: "JalanKitaKit"),
        .testTarget(name: "JalanKitaKitTests", dependencies: ["JalanKitaKit"]),
    ]
)

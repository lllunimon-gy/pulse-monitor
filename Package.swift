// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Pulse",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [.library(name: "Pulse", targets: ["Pulse", "PulseObjC"])],
    targets: [

        .target(name: "PulseObjC", publicHeadersPath: "include"),
        .target(name: "Pulse", dependencies: ["PulseObjC"]),

        .testTarget(name: "PulseTests", dependencies: ["Pulse"])
    ]
)

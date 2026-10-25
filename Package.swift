// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "FanControl",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "CSMC", linkerSettings: [.linkedFramework("IOKit")]),
        .target(name: "FanKit", dependencies: ["CSMC"]),
        .executableTarget(name: "fanctl", dependencies: ["FanKit"]),
        .executableTarget(name: "FanControl", dependencies: ["FanKit"]),
    ]
)

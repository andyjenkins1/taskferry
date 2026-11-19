// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TaskFerry",
    platforms: [.macOS(.v14)],
    targets: [
        // Pure logic: no EventKit, no UI. Everything here is unit tested.
        .target(name: "TaskFerryCore"),
        .executableTarget(name: "TaskFerry", dependencies: ["TaskFerryCore"]),
        .testTarget(name: "TaskFerryCoreTests", dependencies: ["TaskFerryCore"]),
    ]
)

// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Tackroom",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TackroomKit", targets: ["TackroomKit"]),
        .executable(name: "TackroomApp", targets: ["TackroomApp"]),
        .executable(name: "tackroom", targets: ["tackroom"]),
    ],
    targets: [
        // All logic lives here; the app and the CLI are thin shells.
        .target(name: "TackroomKit"),
        .executableTarget(name: "TackroomApp", dependencies: ["TackroomKit"]),
        .executableTarget(name: "tackroom", dependencies: ["TackroomKit"]),
        .testTarget(name: "TackroomKitTests", dependencies: ["TackroomKit"]),
    ]
)

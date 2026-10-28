// swift-tools-version:5.9
// Logic shared by the watch and iPhone apps. No WatchConnectivity or AVFoundation, so it
// tests on the Mac (scripts/test-kit.sh).
import PackageDescription

let package = Package(
    name: "AudayKit",
    platforms: [.watchOS(.v10), .iOS(.v17), .macOS(.v14)],
    products: [.library(name: "AudayKit", targets: ["AudayKit"])],
    targets: [
        .target(name: "AudayKit"),
        .testTarget(name: "AudayKitTests", dependencies: ["AudayKit"]),
    ]
)

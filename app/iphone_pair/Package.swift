// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "auday-replica-pair",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "../../watch/AudayKit")],
    targets: [.executableTarget(name: "auday-replica-pair", dependencies: ["AudayKit"])]
)

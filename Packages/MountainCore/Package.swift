// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "MountainCore",
  platforms: [.macOS("26.0")],
  products: [
    .library(name: "MountainCore", targets: ["MountainCore"]),
    .executable(name: "mountain-verify", targets: ["MountainVerify"]),
  ],
  targets: [
    .target(name: "MountainCore"),
    .executableTarget(name: "MountainVerify", dependencies: ["MountainCore"]),
    .testTarget(name: "MountainCoreTests", dependencies: ["MountainCore"]),
  ]
)

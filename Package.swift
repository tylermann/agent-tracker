// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "AgentTracker",
  platforms: [.macOS(.v14)],
  products: [
    .library(name: "AgentTrackerCore", targets: ["AgentTrackerCore"]),
    .executable(name: "agent-tracker", targets: ["AgentTrackerCLI"]),
    .executable(name: "AgentTracker", targets: ["AgentTrackerApp"]),
  ],
  targets: [
    .systemLibrary(name: "CSQLite"),
    .target(
      name: "AgentTrackerCore",
      dependencies: ["CSQLite"],
      linkerSettings: [
        // sqlite3 is linked by the CSQLite system-library modulemap.
        .linkedFramework("Security"),
        .linkedFramework("LocalAuthentication"),
      ]
    ),
    .executableTarget(
      name: "AgentTrackerCLI",
      dependencies: ["AgentTrackerCore"]
    ),
    .executableTarget(
      name: "AgentTrackerApp",
      dependencies: ["AgentTrackerCore"],
      resources: [.process("Resources")]
    ),
    .testTarget(
      name: "AgentTrackerCoreTests",
      dependencies: ["AgentTrackerCore"]
    ),
  ]
)

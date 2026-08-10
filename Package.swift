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
      linkerSettings: [.linkedLibrary("sqlite3")]
    ),
    .executableTarget(
      name: "AgentTrackerCLI",
      dependencies: ["AgentTrackerCore"]
    ),
    .executableTarget(
      name: "AgentTrackerApp",
      dependencies: ["AgentTrackerCore"]
    ),
    .testTarget(
      name: "AgentTrackerCoreTests",
      dependencies: ["AgentTrackerCore"]
    ),
  ]
)

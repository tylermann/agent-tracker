import AgentTrackerCore
import Foundation

/// Launches the Agent Tracker app in the background when this helper runs from inside its bundle.
enum AppLauncher {
  static func launchIfAvailable() {
    var candidate = URL(fileURLWithPath: CurrentExecutable.path()).standardizedFileURL
      .deletingLastPathComponent()
    var appURL: URL?
    while candidate.path != "/" {
      if candidate.pathExtension == "app",
        Bundle(url: candidate)?.bundleIdentifier == AppIdentity.bundleIdentifier
      {
        appURL = candidate
        break
      }
      candidate.deleteLastPathComponent()
    }
    guard let appURL else { return }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = ["-gj", appURL.path]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try? process.run()
  }
}

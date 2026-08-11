import Foundation

public struct AgentTrackerPaths: Sendable {
  public let root: URL

  public init(root: URL? = nil) {
    if let root {
      self.root = root
    } else if let override = ProcessInfo.processInfo.environment["AGENT_TRACKER_DATA_DIR"],
      !override.isEmpty
    {
      self.root = URL(fileURLWithPath: override, isDirectory: true)
    } else {
      let applicationSupport = FileManager.default.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
      ).first!
      self.root = applicationSupport.appendingPathComponent("AgentTracker", isDirectory: true)
    }
  }

  public var inbox: URL { root.appendingPathComponent("events/inbox", isDirectory: true) }
  public var database: URL { root.appendingPathComponent("runs.sqlite3") }

  public func prepare() throws {
    try FileManager.default.createDirectory(
      at: inbox,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: inbox.path)
  }
}

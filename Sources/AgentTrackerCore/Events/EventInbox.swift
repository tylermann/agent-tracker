import Foundation

public final class EventInbox: @unchecked Sendable {
  private let paths: AgentTrackerPaths
  private let encoder: JSONEncoder
  private let decoder: JSONDecoder

  public init(paths: AgentTrackerPaths = AgentTrackerPaths()) throws {
    self.paths = paths
    encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    try paths.prepare()
  }

  public func enqueue(_ event: AgentEvent) throws {
    let data = try encoder.encode(event)
    let fileName = String(
      format: "%.6f-%@.json", event.occurredAt.timeIntervalSince1970, event.eventID.uuidString)
    let destination = paths.inbox.appendingPathComponent(fileName)
    let temporary = paths.inbox.appendingPathComponent(".\(event.eventID.uuidString).tmp")
    try data.write(to: temporary, options: [.atomic])
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
    try FileManager.default.moveItem(at: temporary, to: destination)
    DistributedNotificationCenter.default().postNotificationName(
      AgentTrackerNotification.inboxChanged,
      object: nil,
      deliverImmediately: true
    )
  }

  public func pendingURLs() throws -> [URL] {
    try FileManager.default.contentsOfDirectory(
      at: paths.inbox,
      includingPropertiesForKeys: nil,
      options: [.skipsHiddenFiles]
    )
    .filter { $0.pathExtension == "json" }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }
  }

  public func decode(at url: URL) throws -> AgentEvent {
    try decoder.decode(AgentEvent.self, from: Data(contentsOf: url))
  }

  public func remove(at url: URL) throws {
    try FileManager.default.removeItem(at: url)
  }
}

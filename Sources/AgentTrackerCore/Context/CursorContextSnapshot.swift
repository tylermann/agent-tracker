import Foundation

/// The latest context-window reading reported by Cursor for one tracked run.
///
/// Cursor's status-line callback can fire several times while a response streams. Keeping this in
/// one atomically replaced file avoids turning UI telemetry into lifecycle events and SQLite
/// writes. The app reads only `context`; the remaining fields make the file diagnosable and leave
/// room to match an orphan run by Cursor's conversation ID.
public struct CursorContextSnapshot: Codable, Equatable, Sendable {
  public enum Source: String, Codable, Sendable {
    case statusLine
    case stopHook
  }

  public var runID: String
  public var sessionID: String
  public var context: SessionContext
  public var source: Source
  public var updatedAt: Date

  public init(
    runID: String,
    sessionID: String,
    context: SessionContext,
    source: Source = .statusLine,
    updatedAt: Date = Date()
  ) {
    self.runID = runID
    self.sessionID = sessionID
    self.context = context
    self.source = source
    self.updatedAt = updatedAt
  }
}

/// Parses both Cursor's live status-line payload and the token counters attached to recent Stop
/// hooks. The status-line percentage is authoritative; Stop-hook parsing is deliberately a
/// fallback for users who already own Cursor's single configurable status-line slot.
public enum CursorContextPayloadParser {
  public static func statusLine(
    _ data: Data,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    now: Date = Date()
  ) throws -> CursorContextSnapshot? {
    let root = try object(data)
    guard let sessionID = nonempty(root["session_id"]),
      let window = dictionary(root["context_window"]),
      let windowTokens = integer(window["context_window_size"]),
      windowTokens > 0
    else { return nil }

    let usedTokens: Int?
    if let percent = number(window["used_percentage"]), percent >= 0 {
      usedTokens = Int((Double(windowTokens) * percent / 100).rounded())
    } else {
      usedTokens = integer(window["total_input_tokens"])
    }
    guard let usedTokens, usedTokens > 0 else { return nil }

    let modelObject = dictionary(root["model"])
    let model = nonempty(modelObject?["id"]) ?? nonempty(modelObject?["display_name"])
    return CursorContextSnapshot(
      runID: runID(environment: environment, sessionID: sessionID),
      sessionID: sessionID,
      context: SessionContext(
        usedTokens: usedTokens, windowTokens: windowTokens, model: model),
      source: .statusLine,
      updatedAt: now
    )
  }

  public static func stopHook(
    _ data: Data,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    now: Date = Date()
  ) throws -> CursorContextSnapshot? {
    let root = try object(data)
    guard
      let sessionID =
        nonempty(root["conversation_id"]) ?? nonempty(root["session_id"]),
      let windowTokens = hookWindowTokens(root), windowTokens > 0
    else { return nil }

    let usedTokens =
      (integer(root["input_tokens"]) ?? 0) + (integer(root["output_tokens"]) ?? 0)
      + (integer(root["cache_read_tokens"]) ?? 0)
      + (integer(root["cache_write_tokens"]) ?? 0)
    guard usedTokens > 0 else { return nil }
    let model = nonempty(root["model_id"]) ?? nonempty(root["model"])
    return CursorContextSnapshot(
      runID: runID(environment: environment, sessionID: sessionID),
      sessionID: sessionID,
      context: SessionContext(
        usedTokens: usedTokens, windowTokens: windowTokens, model: model),
      source: .stopHook,
      updatedAt: now
    )
  }

  private static func hookWindowTokens(_ root: [String: Any]) -> Int? {
    if let explicit = integer(root["context_window_size"]) { return explicit }
    if let parameters = root["model_params"] as? [[String: Any]],
      let context = parameters.first(where: { nonempty($0["id"]) == "context" }),
      let value = nonempty(context["value"]), let parsed = abbreviatedTokens(value)
    {
      return parsed
    }
    guard let model = nonempty(root["model_id"]) ?? nonempty(root["model"]) else {
      return nil
    }
    return CursorModelContextWindow.tokens(for: model)
  }

  private static func abbreviatedTokens(_ value: String) -> Int? {
    let normalized = value.lowercased().replacingOccurrences(of: "_", with: "")
      .replacingOccurrences(of: ",", with: "")
    if normalized.hasSuffix("m"), let number = Double(normalized.dropLast()) {
      return Int(number * 1_000_000)
    }
    if normalized.hasSuffix("k"), let number = Double(normalized.dropLast()) {
      return Int(number * 1_000)
    }
    return Int(normalized)
  }

  private static func runID(environment: [String: String], sessionID: String) -> String {
    environment["AGENT_TRACKER_RUN_ID"].flatMap { $0.isEmpty ? nil : $0 }
      ?? "orphan-\(sessionID)"
  }

  private static func object(_ data: Data) throws -> [String: Any] {
    guard !data.isEmpty else { return [:] }
    return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
  }

  private static func dictionary(_ value: Any?) -> [String: Any]? {
    value as? [String: Any]
  }

  private static func nonempty(_ value: Any?) -> String? {
    guard let string = value as? String, !string.isEmpty else { return nil }
    return string
  }

  private static func integer(_ value: Any?) -> Int? {
    if let int = value as? Int { return int }
    if let number = value as? NSNumber { return number.intValue }
    if let string = value as? String { return Int(string) }
    return nil
  }

  private static func number(_ value: Any?) -> Double? {
    if let double = value as? Double { return double }
    if let number = value as? NSNumber { return number.doubleValue }
    if let string = value as? String { return Double(string) }
    return nil
  }
}

/// Default context sizes used only by the Stop-hook fallback. Cursor's live status-line payload
/// supplies the actual denominator and does not consult this table.
private enum CursorModelContextWindow {
  private static let table: [(needle: String, tokens: Int)] = [
    ("gpt-5.6", 272_000),
    ("grok-4.6", 256_000),
    ("grok-4.5", 256_000),
    ("composer-2.5", 200_000),
    ("gemini-3", 200_000),
    ("claude-fable-5", 300_000),
    ("claude-opus-5", 300_000),
    ("claude-sonnet-5", 200_000),
  ]

  static func tokens(for model: String) -> Int? {
    let normalized = model.lowercased()
    return table.first { normalized.contains($0.needle) }?.tokens
  }
}

public final class CursorContextSnapshotStore: @unchecked Sendable {
  private let paths: AgentTrackerPaths
  private let fileManager: FileManager
  private let encoder: JSONEncoder
  private let decoder: JSONDecoder

  public init(
    paths: AgentTrackerPaths = AgentTrackerPaths(),
    fileManager: FileManager = .default
  ) throws {
    self.paths = paths
    self.fileManager = fileManager
    encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    try paths.prepare()
  }

  public func write(_ snapshot: CursorContextSnapshot) throws {
    // The Stop hook exposes useful counters but not Cursor's authoritative window calculation. Do
    // not let it immediately overwrite a live status-line reading for the same conversation. An
    // old reading no longer wins, so the fallback can recover if Cursor stops invoking the bridge.
    if snapshot.source == .stopHook,
      let existing = try? read(forRunID: snapshot.runID),
      existing.source == .statusLine,
      existing.sessionID == snapshot.sessionID,
      snapshot.updatedAt.timeIntervalSince(existing.updatedAt) < 30
    {
      return
    }
    let data = try encoder.encode(snapshot)
    try AtomicFileWriter.write(
      data, to: url(forRunID: snapshot.runID), permissions: 0o600, backup: false,
      fileManager: fileManager)
    DistributedNotificationCenter.default().postNotificationName(
      AgentTrackerNotification.inboxChanged,
      object: nil,
      deliverImmediately: true
    )
  }

  public func read(forRunID runID: String) throws -> CursorContextSnapshot {
    try decoder.decode(
      CursorContextSnapshot.self, from: Data(contentsOf: url(forRunID: runID)))
  }

  public func url(forRunID runID: String) -> URL {
    paths.contextSnapshots.appendingPathComponent(Self.fileName(forRunID: runID))
  }

  /// Base64url keeps arbitrary run IDs inside one directory without lossy sanitizing or collisions.
  static func fileName(forRunID runID: String) -> String {
    let encoded = Data(runID.utf8).base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
    return "\(encoded).json"
  }
}

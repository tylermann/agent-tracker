import CSQLite
import Foundation

public enum RunStoreError: LocalizedError {
  case open(String)
  case sqlite(String)

  public var errorDescription: String? {
    switch self {
    case .open(let message): "Unable to open the Agent Tracker database: \(message)"
    case .sqlite(let message): "Agent Tracker database error: \(message)"
    }
  }
}

public final class RunStore: @unchecked Sendable {
  private var database: OpaquePointer?
  private let lock = NSLock()
  private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

  public init(paths: AgentTrackerPaths = AgentTrackerPaths()) throws {
    try paths.prepare()
    var handle: OpaquePointer?
    let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
    guard sqlite3_open_v2(paths.database.path, &handle, flags, nil) == SQLITE_OK else {
      let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
      sqlite3_close(handle)
      throw RunStoreError.open(message)
    }
    database = handle
    try execute("PRAGMA journal_mode=WAL")
    try execute("PRAGMA busy_timeout=1000")
    try execute("PRAGMA foreign_keys=ON")
    try execute(Self.schema)
    try migrateHarnessQualifiedOrphans()
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600], ofItemAtPath: paths.database.path)
  }

  deinit {
    sqlite3_close(database)
  }

  @discardableResult
  public func apply(_ event: AgentEvent) throws -> TrackedRun {
    try withLock {
      try executeUnlocked("BEGIN IMMEDIATE")
      do {
        let inserted = try insertEventUnlocked(event)
        if !inserted, let existing = try runUnlocked(id: event.runID) {
          try executeUnlocked("COMMIT")
          return existing
        }

        var run =
          try runUnlocked(id: event.runID)
          ?? TrackedRun(
            runID: event.runID,
            harness: event.harness,
            startedAt: event.occurredAt,
            lastEventAt: event.occurredAt
          )
        reduce(event, into: &run)
        let metadata = GitMetadata.read(from: run.workingDirectory)
        if run.projectRoot == nil { run.projectRoot = metadata.root }
        if metadata.branch != nil { run.branch = metadata.branch }
        try upsertUnlocked(run)
        try executeUnlocked("COMMIT")
        return run
      } catch {
        try? executeUnlocked("ROLLBACK")
        throw error
      }
    }
  }

  public func runs(includeRecentSince cutoff: Date = Date().addingTimeInterval(-86_400)) throws
    -> [TrackedRun]
  {
    try withLock {
      let sql = """
        SELECT run_id, harness, harness_session_id, terminal_id, executable, pid,
               project_root, cwd, branch, prompt_preview, status, unread,
               started_at, last_event_at, ended_at, exit_code
        FROM runs
        WHERE ended_at IS NULL OR ended_at >= ?
        ORDER BY
            CASE status
                WHEN 'needsAttention' THEN 0
                WHEN 'waiting' THEN 1
                WHEN 'working' THEN 2
                WHEN 'starting' THEN 3
                ELSE 4
            END,
            last_event_at DESC
        """
      let statement = try prepareUnlocked(sql)
      defer { sqlite3_finalize(statement) }
      sqlite3_bind_double(statement, 1, cutoff.timeIntervalSince1970)
      var result: [TrackedRun] = []
      while sqlite3_step(statement) == SQLITE_ROW {
        result.append(decodeRun(statement))
      }
      return result
    }
  }

  public func run(id: String) throws -> TrackedRun? {
    try withLock { try runUnlocked(id: id) }
  }

  public func markSeen(runID: String) throws {
    try update("UPDATE runs SET unread = 0 WHERE run_id = ?", values: [.text(runID)])
  }

  public func markUnavailable(runID: String, at date: Date = Date()) throws {
    try update(
      "UPDATE runs SET status = 'unavailable', ended_at = ?, last_event_at = ? WHERE run_id = ? AND ended_at IS NULL",
      values: [
        .double(date.timeIntervalSince1970), .double(date.timeIntervalSince1970), .text(runID),
      ]
    )
  }

  public func clearHistory() throws {
    try update("DELETE FROM runs WHERE ended_at IS NOT NULL", values: [])
  }

  public func prune(olderThan cutoff: Date) throws {
    try withLock {
      try updateUnlocked(
        "DELETE FROM events WHERE occurred_at < ?",
        values: [.double(cutoff.timeIntervalSince1970)]
      )
      try updateUnlocked(
        "DELETE FROM runs WHERE ended_at IS NOT NULL AND ended_at < ?",
        values: [.double(cutoff.timeIntervalSince1970)]
      )
    }
  }

  private func reduce(_ event: AgentEvent, into run: inout TrackedRun) {
    // Cursor emits both native and Claude Code-compatible hooks. Once a native Cursor event
    // identifies the shared run, do not let a later compatibility event relabel it as Claude.
    if run.harness != .cursor || event.harness == .cursor {
      run.harness = event.harness
    }
    run.harnessSessionID = event.harnessSessionID ?? run.harnessSessionID
    run.ghosttyTerminalID = event.ghosttyTerminalID ?? run.ghosttyTerminalID
    run.executable = event.executable ?? run.executable
    run.processID = event.processID ?? run.processID
    run.workingDirectory = event.cwd ?? run.workingDirectory
    if run.promptPreview == nil, let preview = event.promptPreview, !preview.isEmpty {
      run.promptPreview = preview
    }
    run.lastEventAt = max(run.lastEventAt, event.occurredAt)

    switch event.kind {
    case .processStarted, .sessionStarted:
      if run.status == .starting || run.status == .ended || run.status == .unavailable {
        run.status = .starting
      }
      run.endedAt = nil
    case .promptSubmitted, .activity:
      run.status = .working
      run.unreadAttention = false
      run.endedAt = nil
    case .attentionRequired:
      run.status = .needsAttention
      run.unreadAttention = true
    case .turnStopped:
      run.status = .waiting
      run.unreadAttention = true
    case .sessionEnded, .processExited:
      run.status = .ended
      run.unreadAttention = false
      run.endedAt = event.occurredAt
      run.exitCode = event.exitCode ?? run.exitCode
    }
  }

  private enum Binding {
    case text(String)
    case int(Int32)
    case double(Double)
    case null
  }

  private func withLock<T>(_ body: () throws -> T) rethrows -> T {
    lock.lock()
    defer { lock.unlock() }
    return try body()
  }

  private func execute(_ sql: String) throws {
    try withLock { try executeUnlocked(sql) }
  }

  private func executeUnlocked(_ sql: String) throws {
    var error: UnsafeMutablePointer<CChar>?
    guard sqlite3_exec(database, sql, nil, nil, &error) == SQLITE_OK else {
      let message = error.map { String(cString: $0) } ?? errorMessage
      sqlite3_free(error)
      throw RunStoreError.sqlite(message)
    }
  }

  private func prepareUnlocked(_ sql: String) throws -> OpaquePointer {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
      let statement
    else {
      throw RunStoreError.sqlite(errorMessage)
    }
    return statement
  }

  private func bind(_ values: [Binding], to statement: OpaquePointer) {
    for (offset, value) in values.enumerated() {
      let index = Int32(offset + 1)
      switch value {
      case .text(let text): sqlite3_bind_text(statement, index, text, -1, Self.transient)
      case .int(let number): sqlite3_bind_int(statement, index, number)
      case .double(let number): sqlite3_bind_double(statement, index, number)
      case .null: sqlite3_bind_null(statement, index)
      }
    }
  }

  private func update(_ sql: String, values: [Binding]) throws {
    try withLock { try updateUnlocked(sql, values: values) }
  }

  private func updateUnlocked(_ sql: String, values: [Binding]) throws {
    let statement = try prepareUnlocked(sql)
    defer { sqlite3_finalize(statement) }
    bind(values, to: statement)
    guard sqlite3_step(statement) == SQLITE_DONE else {
      throw RunStoreError.sqlite(errorMessage)
    }
  }

  private func insertEventUnlocked(_ event: AgentEvent) throws -> Bool {
    try updateUnlocked(
      "INSERT OR IGNORE INTO events(event_id, run_id, kind, occurred_at) VALUES (?, ?, ?, ?)",
      values: [
        .text(event.eventID.uuidString), .text(event.runID), .text(event.kind.rawValue),
        .double(event.occurredAt.timeIntervalSince1970),
      ]
    )
    return sqlite3_changes(database) > 0
  }

  private func upsertUnlocked(_ run: TrackedRun) throws {
    let sql = """
      INSERT INTO runs(
          run_id, harness, harness_session_id, terminal_id, executable, pid,
          project_root, cwd, branch, prompt_preview, status, unread,
          started_at, last_event_at, ended_at, exit_code
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(run_id) DO UPDATE SET
          harness=excluded.harness, harness_session_id=excluded.harness_session_id,
          terminal_id=excluded.terminal_id, executable=excluded.executable, pid=excluded.pid,
          project_root=excluded.project_root, cwd=excluded.cwd, branch=excluded.branch,
          prompt_preview=excluded.prompt_preview, status=excluded.status, unread=excluded.unread,
          started_at=excluded.started_at, last_event_at=excluded.last_event_at,
          ended_at=excluded.ended_at, exit_code=excluded.exit_code
      """
    try updateUnlocked(
      sql,
      values: [
        .text(run.runID), .text(run.harness.rawValue), optional(run.harnessSessionID),
        optional(run.ghosttyTerminalID), optional(run.executable), optional(run.processID),
        optional(run.projectRoot), optional(run.workingDirectory), optional(run.branch),
        optional(run.promptPreview), .text(run.status.rawValue), .int(run.unreadAttention ? 1 : 0),
        .double(run.startedAt.timeIntervalSince1970),
        .double(run.lastEventAt.timeIntervalSince1970),
        optional(run.endedAt), optional(run.exitCode),
      ])
  }

  private func runUnlocked(id: String) throws -> TrackedRun? {
    let statement = try prepareUnlocked(
      """
      SELECT run_id, harness, harness_session_id, terminal_id, executable, pid,
             project_root, cwd, branch, prompt_preview, status, unread,
             started_at, last_event_at, ended_at, exit_code
      FROM runs WHERE run_id = ? LIMIT 1
      """)
    defer { sqlite3_finalize(statement) }
    bind([.text(id)], to: statement)
    guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
    return decodeRun(statement)
  }

  private func migrateHarnessQualifiedOrphans() throws {
    try withLock {
      try executeUnlocked("BEGIN IMMEDIATE")
      do {
        let statement = try prepareUnlocked(
          """
          SELECT run_id, harness, harness_session_id, terminal_id, executable, pid,
                 project_root, cwd, branch, prompt_preview, status, unread,
                 started_at, last_event_at, ended_at, exit_code
          FROM runs
          WHERE harness_session_id IS NOT NULL AND run_id LIKE 'orphan-%'
          """)
        defer { sqlite3_finalize(statement) }

        var legacySessions = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW {
          let run = decodeRun(statement)
          guard let sessionID = run.harnessSessionID,
            run.runID == "orphan-\(run.harness.rawValue)-\(sessionID)"
          else { continue }
          legacySessions.insert(sessionID)
        }

        for sessionID in legacySessions {
          try migrateHarnessQualifiedOrphanUnlocked(sessionID: sessionID)
        }
        try executeUnlocked("COMMIT")
      } catch {
        try? executeUnlocked("ROLLBACK")
        throw error
      }
    }
  }

  private func migrateHarnessQualifiedOrphanUnlocked(sessionID: String) throws {
    let canonicalID = "orphan-\(sessionID)"
    let legacyIDs = Harness.allCases.map { "orphan-\($0.rawValue)-\(sessionID)" }
    let candidates = try ([canonicalID] + legacyIDs).compactMap { try runUnlocked(id: $0) }
    guard !candidates.isEmpty else { return }

    let preferred = candidates.max { lhs, rhs in
      if lhs.lastEventAt != rhs.lastEventAt {
        return lhs.lastEventAt < rhs.lastEventAt
      }
      return harnessPriority(lhs.harness) < harnessPriority(rhs.harness)
    }!
    let preferredHarness =
      candidates.contains(where: { $0.harness == .cursor }) ? Harness.cursor : preferred.harness

    var merged = preferred
    merged.runID = canonicalID
    merged.harness = preferredHarness
    merged.startedAt = candidates.map(\.startedAt).min() ?? preferred.startedAt
    merged.lastEventAt = candidates.map(\.lastEventAt).max() ?? preferred.lastEventAt

    let metadataOrder =
      candidates.filter { $0.harness == preferredHarness }
      + candidates.filter { $0.harness != preferredHarness }
    merged.harnessSessionID = metadataOrder.compactMap(\.harnessSessionID).first
    merged.ghosttyTerminalID = metadataOrder.compactMap(\.ghosttyTerminalID).first
    merged.executable = metadataOrder.compactMap(\.executable).first
    merged.processID = metadataOrder.compactMap(\.processID).first
    merged.projectRoot = metadataOrder.compactMap(\.projectRoot).first
    merged.workingDirectory = metadataOrder.compactMap(\.workingDirectory).first
    merged.branch = metadataOrder.compactMap(\.branch).first
    merged.promptPreview = metadataOrder.compactMap(\.promptPreview).first

    for run in candidates where run.runID != canonicalID {
      try updateUnlocked(
        "UPDATE events SET run_id = ? WHERE run_id = ?",
        values: [.text(canonicalID), .text(run.runID)]
      )
      try updateUnlocked("DELETE FROM runs WHERE run_id = ?", values: [.text(run.runID)])
    }
    try upsertUnlocked(merged)
  }

  private func harnessPriority(_ harness: Harness) -> Int {
    harness == .cursor ? 1 : 0
  }

  private func decodeRun(_ statement: OpaquePointer) -> TrackedRun {
    TrackedRun(
      runID: text(statement, 0) ?? "",
      harness: Harness(rawValue: text(statement, 1) ?? "") ?? .claude,
      harnessSessionID: text(statement, 2),
      ghosttyTerminalID: text(statement, 3),
      executable: text(statement, 4),
      processID: nullableInt(statement, 5),
      projectRoot: text(statement, 6),
      workingDirectory: text(statement, 7),
      branch: text(statement, 8),
      promptPreview: text(statement, 9),
      status: RunStatus(rawValue: text(statement, 10) ?? "") ?? .unavailable,
      unreadAttention: sqlite3_column_int(statement, 11) != 0,
      startedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 12)),
      lastEventAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 13)),
      endedAt: nullableDate(statement, 14),
      exitCode: nullableInt(statement, 15)
    )
  }

  private func text(_ statement: OpaquePointer, _ index: Int32) -> String? {
    guard sqlite3_column_type(statement, index) != SQLITE_NULL,
      let value = sqlite3_column_text(statement, index)
    else { return nil }
    return String(cString: value)
  }

  private func nullableInt(_ statement: OpaquePointer, _ index: Int32) -> Int32? {
    sqlite3_column_type(statement, index) == SQLITE_NULL
      ? nil : sqlite3_column_int(statement, index)
  }

  private func nullableDate(_ statement: OpaquePointer, _ index: Int32) -> Date? {
    sqlite3_column_type(statement, index) == SQLITE_NULL
      ? nil
      : Date(timeIntervalSince1970: sqlite3_column_double(statement, index))
  }

  private func optional(_ value: String?) -> Binding { value.map(Binding.text) ?? .null }
  private func optional(_ value: Int32?) -> Binding { value.map(Binding.int) ?? .null }
  private func optional(_ value: Date?) -> Binding {
    value.map { .double($0.timeIntervalSince1970) } ?? .null
  }

  private var errorMessage: String {
    database.map { String(cString: sqlite3_errmsg($0)) } ?? "database is closed"
  }

  private static let schema = """
    CREATE TABLE IF NOT EXISTS events(
        event_id TEXT PRIMARY KEY,
        run_id TEXT NOT NULL,
        kind TEXT NOT NULL,
        occurred_at REAL NOT NULL
    );
    CREATE INDEX IF NOT EXISTS events_run_id ON events(run_id);
    CREATE TABLE IF NOT EXISTS runs(
        run_id TEXT PRIMARY KEY,
        harness TEXT NOT NULL,
        harness_session_id TEXT,
        terminal_id TEXT,
        executable TEXT,
        pid INTEGER,
        project_root TEXT,
        cwd TEXT,
        branch TEXT,
        prompt_preview TEXT,
        status TEXT NOT NULL,
        unread INTEGER NOT NULL DEFAULT 0,
        started_at REAL NOT NULL,
        last_event_at REAL NOT NULL,
        ended_at REAL,
        exit_code INTEGER
    );
    CREATE INDEX IF NOT EXISTS runs_status ON runs(status, last_event_at DESC);
    """
}

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

public struct RunList: Sendable {
  public let runs: [TrackedRun]
  public let recentCount: Int

  public init(runs: [TrackedRun], recentCount: Int) {
    self.runs = runs
    self.recentCount = recentCount
  }
}

public final class RunStore: @unchecked Sendable {
  /// Git status is only worth a subprocess when the user is about to look at the row.
  static let diffstatEventKinds: Set<AgentEventKind> = [
    .attentionRequired, .turnStopped, .sessionEnded, .processExited,
  ]

  let database: SQLiteDatabase
  private let lock = NSLock()

  public init(paths: AgentTrackerPaths = AgentTrackerPaths()) throws {
    try paths.prepare()
    let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
    database = try SQLiteDatabase(path: paths.database.path, flags: flags)
    try execute("PRAGMA journal_mode=WAL")
    try execute("PRAGMA busy_timeout=1000")
    try execute("PRAGMA foreign_keys=ON")
    try execute(Self.schema)
    try migrateRunGitDiffstatColumns()
    try migrateRunTurnTimingColumns()
    try migrateHarnessQualifiedOrphans()
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600], ofItemAtPath: paths.database.path)
  }

  @discardableResult
  public func apply(_ event: AgentEvent) throws -> TrackedRun {
    let result: (run: TrackedRun, inserted: Bool) = try withLock {
      try database.withTransaction {
        let inserted = try insertEventUnlocked(event)
        if !inserted, let existing = try runUnlocked(id: event.runID) {
          return (existing, false)
        }

        var run =
          try runUnlocked(id: event.runID)
          ?? TrackedRun(
            runID: event.runID,
            harness: event.harness,
            startedAt: event.occurredAt,
            lastEventAt: event.occurredAt
          )
        RunReducer.reduce(event, into: &run)
        try upsertUnlocked(run)
        return (run, true)
      }
    }

    guard result.inserted else { return result.run }

    // Activity ticks are frequent and do not change what the user needs to see. Refresh git only
    // when a row still needs a branch/root, or when the run is asking for attention / has stopped.
    let includeDiffstat = Self.diffstatEventKinds.contains(event.kind)
    let missingIdentity = result.run.projectRoot == nil || result.run.branch == nil
    guard includeDiffstat || (missingIdentity && event.kind != .activity) else {
      return result.run
    }

    // `Process.waitUntilExit()` in GitMetadata can service the main run loop. Never invoke it while
    // holding the store lock: a timer or distributed notification may re-enter the model refresh
    // and synchronously attempt to acquire this same lock.
    let metadata = GitMetadata.read(
      from: result.run.workingDirectory, includeDiffstat: includeDiffstat)
    guard metadata.root != nil || metadata.branch != nil || metadata.diffstat != nil else {
      return result.run
    }

    return try withLock {
      // A newer event may have changed the working directory while metadata was being read. Only
      // apply results that still describe the current run, and preserve any newer run state.
      guard var latest = try runUnlocked(id: event.runID) else { return result.run }
      guard latest.workingDirectory == result.run.workingDirectory else { return latest }
      if latest.projectRoot == nil { latest.projectRoot = metadata.root }
      if metadata.branch != nil { latest.branch = metadata.branch }
      if let diffstat = metadata.diffstat { latest.gitDiffstat = diffstat }
      try upsertUnlocked(latest)
      return latest
    }
  }

  public func runs(includeRecentSince cutoff: Date = Date().addingTimeInterval(-86_400)) throws
    -> [TrackedRun]
  {
    try withLock {
      let sql = """
        SELECT \(RunRowCodec.columns)
        FROM runs
        WHERE ended_at IS NULL OR ended_at >= ?
        \(RunRowCodec.statusPriorityOrder)
        """
      let statement = try database.prepare(sql)
      defer { sqlite3_finalize(statement) }
      sqlite3_bind_double(statement, 1, cutoff.timeIntervalSince1970)
      var result: [TrackedRun] = []
      while sqlite3_step(statement) == SQLITE_ROW {
        result.append(RunRowCodec.decode(statement))
      }
      return result
    }
  }

  /// Returns every active run plus at most `recentLimit` terminal runs. Keeping the terminal
  /// portion bounded makes this suitable for refresh-driven UI while `recentCount` still lets the
  /// caller present an accurate "show more" affordance.
  public func runList(
    recentLimit: Int,
    includeRecentSince cutoff: Date = Date().addingTimeInterval(-86_400)
  ) throws -> RunList {
    let limit = max(recentLimit, 0)
    return try withLock {
      let countStatement = try database.prepare(
        "SELECT COUNT(*) FROM runs WHERE ended_at IS NOT NULL AND ended_at >= ?")
      defer { sqlite3_finalize(countStatement) }
      sqlite3_bind_double(countStatement, 1, cutoff.timeIntervalSince1970)
      guard sqlite3_step(countStatement) == SQLITE_ROW else {
        throw RunStoreError.sqlite(database.errorMessage)
      }
      let recentCount = Int(sqlite3_column_int64(countStatement, 0))

      let sql = """
        SELECT \(RunRowCodec.columns)
        FROM runs
        WHERE ended_at IS NULL OR run_id IN (
          SELECT run_id
          FROM runs
          WHERE ended_at IS NOT NULL AND ended_at >= ?
          ORDER BY last_event_at DESC
          LIMIT ?
        )
        \(RunRowCodec.statusPriorityOrder)
        """
      let statement = try database.prepare(sql)
      defer { sqlite3_finalize(statement) }
      sqlite3_bind_double(statement, 1, cutoff.timeIntervalSince1970)
      sqlite3_bind_int64(statement, 2, sqlite3_int64(limit))

      var runs: [TrackedRun] = []
      while sqlite3_step(statement) == SQLITE_ROW {
        runs.append(RunRowCodec.decode(statement))
      }
      return RunList(runs: runs, recentCount: recentCount)
    }
  }

  /// Returns only live runs, for work such as process reconciliation that never needs history.
  public func activeRuns() throws -> [TrackedRun] {
    try withLock {
      let statement = try database.prepare(
        """
        SELECT \(RunRowCodec.columns)
        FROM runs
        WHERE ended_at IS NULL
        \(RunRowCodec.statusPriorityOrder)
        """)
      defer { sqlite3_finalize(statement) }
      var runs: [TrackedRun] = []
      while sqlite3_step(statement) == SQLITE_ROW {
        runs.append(RunRowCodec.decode(statement))
      }
      return runs
    }
  }

  public func run(id: String) throws -> TrackedRun? {
    try withLock { try runUnlocked(id: id) }
  }

  public func markSeen(runID: String) throws {
    try update("UPDATE runs SET unread = 0 WHERE run_id = ?", values: [.text(runID)])
  }

  public func markUnavailable(runID: String, at date: Date = Date()) throws {
    // This path does not go through RunReducer, so it has to close out an in-flight working
    // stretch itself; otherwise the row would keep reporting a stale turn length.
    try update(
      """
      UPDATE runs SET status = 'unavailable', ended_at = ?, last_event_at = ?,
          last_turn_duration = CASE
              WHEN working_since IS NOT NULL THEN MAX(0, ? - working_since)
              ELSE last_turn_duration
          END,
          working_since = NULL
      WHERE run_id = ? AND ended_at IS NULL
      """,
      values: [
        .double(date.timeIntervalSince1970), .double(date.timeIntervalSince1970),
        .double(date.timeIntervalSince1970), .text(runID),
      ]
    )
  }

  public func clearHistory() throws {
    try update("DELETE FROM runs WHERE ended_at IS NOT NULL", values: [])
  }

  public func prune(olderThan cutoff: Date) throws {
    try withLock {
      try database.update(
        "DELETE FROM events WHERE occurred_at < ?",
        values: [.double(cutoff.timeIntervalSince1970)]
      )
      try database.update(
        "DELETE FROM runs WHERE ended_at IS NOT NULL AND ended_at < ?",
        values: [.double(cutoff.timeIntervalSince1970)]
      )
    }
  }

  func withLock<T>(_ body: () throws -> T) rethrows -> T {
    lock.lock()
    defer { lock.unlock() }
    return try body()
  }

  private func execute(_ sql: String) throws {
    try withLock { try database.execute(sql) }
  }

  private func update(_ sql: String, values: [SQLiteValue]) throws {
    try withLock { try database.update(sql, values: values) }
  }

  private func insertEventUnlocked(_ event: AgentEvent) throws -> Bool {
    try database.update(
      "INSERT OR IGNORE INTO events(event_id, run_id, kind, occurred_at) VALUES (?, ?, ?, ?)",
      values: [
        .text(event.eventID.uuidString), .text(event.runID), .text(event.kind.rawValue),
        .double(event.occurredAt.timeIntervalSince1970),
      ]
    )
    return database.changedRowCount > 0
  }

  func upsertUnlocked(_ run: TrackedRun) throws {
    try database.update(RunRowCodec.upsertSQL, values: RunRowCodec.bindings(for: run))
  }

  func runUnlocked(id: String) throws -> TrackedRun? {
    let statement = try database.prepare(
      "SELECT \(RunRowCodec.columns) FROM runs WHERE run_id = ? LIMIT 1")
    defer { sqlite3_finalize(statement) }
    database.bind([.text(id)], to: statement)
    guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
    return RunRowCodec.decode(statement)
  }
}

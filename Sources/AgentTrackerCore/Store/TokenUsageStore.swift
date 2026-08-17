import CSQLite
import Foundation

/// Persistence for aggregated token usage. Only per-day counters and scan positions are stored —
/// never transcript content.
extension RunStore {
  private static let tokenUsageUpsertSQL = """
    INSERT INTO token_usage_daily(
        day, harness, model, input_tokens, output_tokens, cache_read_tokens, cache_write_tokens)
    VALUES (?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT(day, harness, model) DO UPDATE SET
        input_tokens = input_tokens + excluded.input_tokens,
        output_tokens = output_tokens + excluded.output_tokens,
        cache_read_tokens = cache_read_tokens + excluded.cache_read_tokens,
        cache_write_tokens = cache_write_tokens + excluded.cache_write_tokens
    """

  private static let scanStateReplaceSQL = """
    INSERT OR REPLACE INTO token_usage_scan_state(path, byte_offset, file_size, modified_at, model)
    VALUES (?, ?, ?, ?, ?)
    """

  /// Commits one scan: counter deltas add onto existing rows, scan states replace their previous
  /// values. Offsets only persist together with the counted deltas, so a crash between scans never
  /// double-counts and never loses counted bytes.
  public func recordTokenUsage(deltas: [TokenUsageRow], states: [TokenUsageScanState]) throws {
    guard !deltas.isEmpty || !states.isEmpty else { return }
    try withLock {
      try database.withTransaction {
        for delta in deltas {
          try database.update(Self.tokenUsageUpsertSQL, values: bindings(for: delta))
        }
        for state in states {
          try database.update(Self.scanStateReplaceSQL, values: bindings(for: state))
        }
      }
    }
  }

  /// Replaces whole harness-days with a freshly fetched aggregate (the Cursor path, where the
  /// provider is re-queried over a trailing window). Idempotent by construction: running the same
  /// replacement twice yields the same rows.
  public func replaceTokenUsage(
    harness: Harness, days: [String], rows: [TokenUsageRow], state: TokenUsageScanState
  ) throws {
    try withLock {
      try database.withTransaction {
        for day in days {
          try database.update(
            "DELETE FROM token_usage_daily WHERE harness = ? AND day = ?",
            values: [.text(harness.rawValue), .text(day)]
          )
        }
        for row in rows {
          try database.update(Self.tokenUsageUpsertSQL, values: bindings(for: row))
        }
        try database.update(Self.scanStateReplaceSQL, values: bindings(for: state))
      }
    }
  }

  public func tokenUsageScanStates() throws -> [String: TokenUsageScanState] {
    try withLock {
      let statement = try database.prepare(
        "SELECT path, byte_offset, file_size, modified_at, model FROM token_usage_scan_state")
      defer { sqlite3_finalize(statement) }
      var states: [String: TokenUsageScanState] = [:]
      while sqlite3_step(statement) == SQLITE_ROW {
        guard let path = sqlite3_column_text(statement, 0) else { continue }
        let state = TokenUsageScanState(
          path: String(cString: path),
          byteOffset: Int(sqlite3_column_int64(statement, 1)),
          fileSize: Int(sqlite3_column_int64(statement, 2)),
          modifiedAt: sqlite3_column_double(statement, 3),
          model: sqlite3_column_text(statement, 4).map { String(cString: $0) }
        )
        states[state.path] = state
      }
      return states
    }
  }

  public func removeTokenUsageScanStates(paths: [String]) throws {
    guard !paths.isEmpty else { return }
    try withLock {
      try database.withTransaction {
        for path in paths {
          try database.update(
            "DELETE FROM token_usage_scan_state WHERE path = ?", values: [.text(path)])
        }
      }
    }
  }

  public func tokenUsage(sinceDay day: String) throws -> [TokenUsageRow] {
    try withLock {
      let statement = try database.prepare(
        """
        SELECT day, harness, model, input_tokens, output_tokens, cache_read_tokens,
            cache_write_tokens
        FROM token_usage_daily
        WHERE day >= ?
        ORDER BY day, harness, model
        """)
      defer { sqlite3_finalize(statement) }
      database.bind([.text(day)], to: statement)
      var rows: [TokenUsageRow] = []
      while sqlite3_step(statement) == SQLITE_ROW {
        guard let day = sqlite3_column_text(statement, 0),
          let harnessName = sqlite3_column_text(statement, 1),
          let harness = Harness(rawValue: String(cString: harnessName)),
          let model = sqlite3_column_text(statement, 2)
        else { continue }
        rows.append(
          TokenUsageRow(
            day: String(cString: day),
            harness: harness,
            model: String(cString: model),
            counters: TokenUsageCounters(
              input: Int(sqlite3_column_int64(statement, 3)),
              output: Int(sqlite3_column_int64(statement, 4)),
              cacheRead: Int(sqlite3_column_int64(statement, 5)),
              cacheWrite: Int(sqlite3_column_int64(statement, 6))
            )
          ))
      }
      return rows
    }
  }

  private func bindings(for row: TokenUsageRow) -> [SQLiteValue] {
    [
      .text(row.day), .text(row.harness.rawValue), .text(row.model),
      .int64(row.counters.input), .int64(row.counters.output),
      .int64(row.counters.cacheRead), .int64(row.counters.cacheWrite),
    ]
  }

  private func bindings(for state: TokenUsageScanState) -> [SQLiteValue] {
    [
      .text(state.path), .int64(state.byteOffset), .int64(state.fileSize),
      .double(state.modifiedAt), state.model.map { .text($0) } ?? .null,
    ]
  }
}

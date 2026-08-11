import CSQLite
import Foundation

/// Single source of truth for the `runs` table's column list and the mapping between `TrackedRun`
/// and statement parameters/result rows. The column order ties `columns`, `bindings(for:)`, and
/// `decode(_:)` together — change one and the other two must follow.
enum RunRowCodec {
  static let columns =
    "run_id, harness, harness_session_id, terminal_id, executable, pid, "
    + "project_root, cwd, branch, prompt_preview, status, unread, "
    + "started_at, last_event_at, ended_at, exit_code"

  /// Shared ORDER BY clause placing runs needing attention first, then by recency.
  static let statusPriorityOrder = """
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

  static let upsertSQL = """
    INSERT INTO runs(\(columns)) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT(run_id) DO UPDATE SET
        harness=excluded.harness, harness_session_id=excluded.harness_session_id,
        terminal_id=excluded.terminal_id, executable=excluded.executable, pid=excluded.pid,
        project_root=excluded.project_root, cwd=excluded.cwd, branch=excluded.branch,
        prompt_preview=excluded.prompt_preview, status=excluded.status, unread=excluded.unread,
        started_at=excluded.started_at, last_event_at=excluded.last_event_at,
        ended_at=excluded.ended_at, exit_code=excluded.exit_code
    """

  static func bindings(for run: TrackedRun) -> [SQLiteValue] {
    [
      .text(run.runID), .text(run.harness.rawValue), optional(run.harnessSessionID),
      optional(run.ghosttyTerminalID), optional(run.executable), optional(run.processID),
      optional(run.projectRoot), optional(run.workingDirectory), optional(run.branch),
      optional(run.promptPreview), .text(run.status.rawValue), .int(run.unreadAttention ? 1 : 0),
      .double(run.startedAt.timeIntervalSince1970),
      .double(run.lastEventAt.timeIntervalSince1970),
      optional(run.endedAt), optional(run.exitCode),
    ]
  }

  static func decode(_ statement: OpaquePointer) -> TrackedRun {
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

  private static func text(_ statement: OpaquePointer, _ index: Int32) -> String? {
    guard sqlite3_column_type(statement, index) != SQLITE_NULL,
      let value = sqlite3_column_text(statement, index)
    else { return nil }
    return String(cString: value)
  }

  private static func nullableInt(_ statement: OpaquePointer, _ index: Int32) -> Int32? {
    sqlite3_column_type(statement, index) == SQLITE_NULL
      ? nil : sqlite3_column_int(statement, index)
  }

  private static func nullableDate(_ statement: OpaquePointer, _ index: Int32) -> Date? {
    sqlite3_column_type(statement, index) == SQLITE_NULL
      ? nil
      : Date(timeIntervalSince1970: sqlite3_column_double(statement, index))
  }

  private static func optional(_ value: String?) -> SQLiteValue { value.map { .text($0) } ?? .null }
  private static func optional(_ value: Int32?) -> SQLiteValue { value.map { .int($0) } ?? .null }
  private static func optional(_ value: Date?) -> SQLiteValue {
    value.map { .double($0.timeIntervalSince1970) } ?? .null
  }
}

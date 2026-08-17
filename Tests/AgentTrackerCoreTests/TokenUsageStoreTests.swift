import XCTest

@testable import AgentTrackerCore

final class TokenUsageStoreTests: XCTestCase {
  private var temporaryDirectory: URL!
  private var store: RunStore!

  override func setUpWithError() throws {
    temporaryDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("AgentTrackerTests-\(UUID().uuidString)")
    store = try RunStore(paths: AgentTrackerPaths(root: temporaryDirectory))
  }

  override func tearDownWithError() throws {
    store = nil
    try? FileManager.default.removeItem(at: temporaryDirectory)
  }

  func testRecordTokenUsageAccumulatesAcrossCommits() throws {
    let delta = TokenUsageRow(
      day: "2026-08-15", harness: .claude, model: "claude-fable-5",
      counters: TokenUsageCounters(input: 100, output: 25, cacheRead: 1_000, cacheWrite: 50))
    try store.recordTokenUsage(deltas: [delta], states: [])
    try store.recordTokenUsage(deltas: [delta], states: [])

    let rows = try store.tokenUsage(sinceDay: "2026-08-01")
    XCTAssertEqual(rows.count, 1)
    XCTAssertEqual(
      rows.first?.counters,
      TokenUsageCounters(input: 200, output: 50, cacheRead: 2_000, cacheWrite: 100))
  }

  func testReplaceTokenUsageIsIdempotentAndScopedToHarness() throws {
    try store.recordTokenUsage(
      deltas: [
        TokenUsageRow(
          day: "2026-08-15", harness: .claude, model: "claude-fable-5",
          counters: TokenUsageCounters(input: 10)),
        TokenUsageRow(
          day: "2026-08-15", harness: .cursor, model: "stale-model",
          counters: TokenUsageCounters(input: 999)),
      ], states: [])

    let replacement = TokenUsageRow(
      day: "2026-08-15", harness: .cursor, model: "grok-4.6",
      counters: TokenUsageCounters(input: 40, output: 4))
    let state = TokenUsageScanState(
      path: TokenUsageScanState.cursorEventsPath, byteOffset: 0, fileSize: 0,
      modifiedAt: 1_700_000_000, model: "2026-08-15")
    for _ in 0..<2 {
      try store.replaceTokenUsage(
        harness: .cursor, days: ["2026-08-15"], rows: [replacement], state: state)
    }

    let rows = try store.tokenUsage(sinceDay: "2026-08-01")
    XCTAssertEqual(rows.count, 2)
    XCTAssertEqual(
      rows.first { $0.harness == .cursor }?.counters, TokenUsageCounters(input: 40, output: 4))
    XCTAssertEqual(rows.first { $0.harness == .cursor }?.model, "grok-4.6")
    XCTAssertEqual(
      rows.first { $0.harness == .claude }?.counters, TokenUsageCounters(input: 10))
  }

  func testScanStateRoundtripKeepsInt64RangeAndModel() throws {
    let overflow = Int(Int32.max) + 1
    let state = TokenUsageScanState(
      path: "/Users/example/.codex/sessions/2026/08/15/rollout-a.jsonl",
      byteOffset: overflow,
      fileSize: overflow + 7,
      modifiedAt: 1_700_000_000.25,
      model: "gpt-5.6-sol"
    )
    let counters = TokenUsageCounters(
      input: overflow, output: 1, cacheRead: overflow, cacheWrite: 0)
    try store.recordTokenUsage(
      deltas: [
        TokenUsageRow(day: "2026-08-15", harness: .codex, model: "gpt-5.6-sol", counters: counters)
      ],
      states: [state])

    XCTAssertEqual(try store.tokenUsageScanStates(), [state.path: state])
    XCTAssertEqual(try store.tokenUsage(sinceDay: "2026-08-15").first?.counters, counters)
  }

  func testRemoveTokenUsageScanStates() throws {
    let keep = TokenUsageScanState(path: "/keep.jsonl", byteOffset: 1, fileSize: 1, modifiedAt: 1)
    let drop = TokenUsageScanState(path: "/drop.jsonl", byteOffset: 2, fileSize: 2, modifiedAt: 2)
    try store.recordTokenUsage(deltas: [], states: [keep, drop])
    try store.removeTokenUsageScanStates(paths: [drop.path])
    XCTAssertEqual(try store.tokenUsageScanStates(), [keep.path: keep])
  }

  func testTokenUsageSinceDayFiltersAndOrders() throws {
    let counters = TokenUsageCounters(input: 1)
    try store.recordTokenUsage(
      deltas: [
        TokenUsageRow(day: "2026-08-16", harness: .claude, model: "b", counters: counters),
        TokenUsageRow(day: "2026-08-14", harness: .claude, model: "a", counters: counters),
        TokenUsageRow(day: "2026-08-15", harness: .codex, model: "a", counters: counters),
      ], states: [])

    let rows = try store.tokenUsage(sinceDay: "2026-08-15")
    XCTAssertEqual(rows.map(\.day), ["2026-08-15", "2026-08-16"])
    XCTAssertEqual(rows.map(\.harness), [.codex, .claude])
  }

  func testExistingDatabaseGainsTokenUsageTables() throws {
    store = nil
    let database = temporaryDirectory.appendingPathComponent("runs.sqlite3")
    try FileManager.default.removeItem(at: database)
    try sqlite3(
      database.path,
      """
      CREATE TABLE events(
          event_id TEXT PRIMARY KEY,
          run_id TEXT NOT NULL,
          kind TEXT NOT NULL,
          occurred_at REAL NOT NULL
      );
      CREATE TABLE runs(
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
      """
    )

    store = try RunStore(paths: AgentTrackerPaths(root: temporaryDirectory))
    let row = TokenUsageRow(
      day: "2026-08-15", harness: .claude, model: "claude-fable-5",
      counters: TokenUsageCounters(input: 5))
    try store.recordTokenUsage(
      deltas: [row],
      states: [TokenUsageScanState(path: "/a.jsonl", byteOffset: 3, fileSize: 3, modifiedAt: 1)])
    XCTAssertEqual(try store.tokenUsage(sinceDay: "2026-08-01"), [row])
    XCTAssertEqual(try store.tokenUsageScanStates().count, 1)
  }

  private func sqlite3(_ path: String, _ sql: String) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
    process.arguments = [path]
    let input = Pipe()
    process.standardInput = input
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    try input.fileHandleForWriting.write(contentsOf: Data(sql.utf8))
    try input.fileHandleForWriting.close()
    process.waitUntilExit()
    XCTAssertEqual(process.terminationStatus, 0, "sqlite3 \(path)")
  }
}

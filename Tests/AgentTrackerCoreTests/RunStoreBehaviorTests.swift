import XCTest

@testable import AgentTrackerCore

/// Characterizes RunStore behaviors not already covered by RunStoreTests, ahead of the store
/// decomposition: restart-from-terminal-states, markUnavailable, clearHistory, and prune.
final class RunStoreBehaviorTests: XCTestCase {
  private var temporaryDirectory: URL!
  private var store: RunStore!
  private let base = Date(timeIntervalSince1970: 1_700_000_000)

  override func setUpWithError() throws {
    temporaryDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("AgentTrackerTests-\(UUID().uuidString)")
    store = try RunStore(paths: AgentTrackerPaths(root: temporaryDirectory))
  }

  override func tearDownWithError() throws {
    store = nil
    try? FileManager.default.removeItem(at: temporaryDirectory)
  }

  private func event(
    _ kind: AgentEventKind, at date: Date, runID: String = "run", exitCode: Int32? = nil
  ) -> AgentEvent {
    AgentEvent(
      occurredAt: date, runID: runID, harness: .claude, kind: kind, cwd: "/tmp",
      exitCode: exitCode)
  }

  func testSessionStartAfterEndRestartsRun() throws {
    _ = try store.apply(event(.processExited, at: base, exitCode: 0))
    XCTAssertEqual(try store.run(id: "run")?.status, .ended)
    XCTAssertNotNil(try store.run(id: "run")?.endedAt)

    _ = try store.apply(event(.sessionStarted, at: base.addingTimeInterval(1)))
    let run = try XCTUnwrap(try store.run(id: "run"))
    XCTAssertEqual(run.status, .starting)
    XCTAssertNil(run.endedAt)
  }

  func testAttentionSurvivesRestartTransitionOnly() throws {
    _ = try store.apply(event(.attentionRequired, at: base))
    _ = try store.apply(event(.sessionStarted, at: base.addingTimeInterval(1)))
    // sessionStarted only resets terminal/starting states; needsAttention is preserved.
    XCTAssertEqual(try store.run(id: "run")?.status, .needsAttention)
  }

  func testMarkUnavailableOnlyAffectsLiveRuns() throws {
    _ = try store.apply(event(.promptSubmitted, at: base))
    try store.markUnavailable(runID: "run", at: base.addingTimeInterval(1))
    var run = try XCTUnwrap(try store.run(id: "run"))
    XCTAssertEqual(run.status, .unavailable)
    XCTAssertEqual(run.endedAt, base.addingTimeInterval(1))

    // A second call must not move endedAt: the update is gated on ended_at IS NULL.
    try store.markUnavailable(runID: "run", at: base.addingTimeInterval(60))
    run = try XCTUnwrap(try store.run(id: "run"))
    XCTAssertEqual(run.endedAt, base.addingTimeInterval(1))
  }

  func testClearHistoryRemovesOnlyEndedRuns() throws {
    _ = try store.apply(event(.processExited, at: base, runID: "ended"))
    _ = try store.apply(event(.promptSubmitted, at: base, runID: "active"))
    try store.clearHistory()
    XCTAssertNil(try store.run(id: "ended"))
    XCTAssertNotNil(try store.run(id: "active"))
  }

  func testPruneRemovesOldEndedRunsAndKeepsActiveOnes() throws {
    _ = try store.apply(event(.processExited, at: base, runID: "old-ended"))
    _ = try store.apply(event(.promptSubmitted, at: base, runID: "old-active"))
    _ = try store.apply(event(.processExited, at: base.addingTimeInterval(100), runID: "new-ended"))

    try store.prune(olderThan: base.addingTimeInterval(50))

    XCTAssertNil(try store.run(id: "old-ended"))
    XCTAssertNotNil(try store.run(id: "old-active"))
    XCTAssertNotNil(try store.run(id: "new-ended"))
  }
}

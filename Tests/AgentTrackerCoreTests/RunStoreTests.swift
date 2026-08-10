import XCTest

@testable import AgentTrackerCore

final class RunStoreTests: XCTestCase {
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

  func testLifecycleReducer() throws {
    let base = Date(timeIntervalSince1970: 1_700_000_000)
    _ = try store.apply(event(.processStarted, at: base))
    XCTAssertEqual(try store.run(id: "run")?.status, .starting)

    _ = try store.apply(event(.promptSubmitted, at: base.addingTimeInterval(1), preview: "Fix it"))
    XCTAssertEqual(try store.run(id: "run")?.status, .working)
    XCTAssertEqual(try store.run(id: "run")?.promptPreview, "Fix it")

    _ = try store.apply(event(.attentionRequired, at: base.addingTimeInterval(2)))
    XCTAssertEqual(try store.run(id: "run")?.status, .needsAttention)
    XCTAssertEqual(try store.run(id: "run")?.unreadAttention, true)

    try store.markSeen(runID: "run")
    XCTAssertEqual(try store.run(id: "run")?.status, .needsAttention)
    XCTAssertEqual(try store.run(id: "run")?.unreadAttention, false)

    _ = try store.apply(event(.promptSubmitted, at: base.addingTimeInterval(3)))
    _ = try store.apply(event(.turnStopped, at: base.addingTimeInterval(4)))
    XCTAssertEqual(try store.run(id: "run")?.status, .waiting)

    _ = try store.apply(event(.processExited, at: base.addingTimeInterval(5)))
    XCTAssertEqual(try store.run(id: "run")?.status, .ended)
    XCTAssertNotNil(try store.run(id: "run")?.endedAt)
  }

  func testDuplicateEventIsIdempotent() throws {
    let duplicate = event(.turnStopped, at: Date())
    _ = try store.apply(duplicate)
    try store.markSeen(runID: "run")
    _ = try store.apply(duplicate)
    XCTAssertEqual(try store.run(id: "run")?.unreadAttention, false)
  }

  func testSameDirectoryRunsRemainSeparate() throws {
    let one = AgentEvent(
      runID: "one", harness: .claude, kind: .processStarted, ghosttyTerminalID: "t1", cwd: "/tmp")
    let two = AgentEvent(
      runID: "two", harness: .codex, kind: .processStarted, ghosttyTerminalID: "t2", cwd: "/tmp")
    _ = try store.apply(one)
    _ = try store.apply(two)
    XCTAssertEqual(try store.runs(includeRecentSince: .distantPast).count, 2)
    XCTAssertNotEqual(
      try store.run(id: "one")?.ghosttyTerminalID, try store.run(id: "two")?.ghosttyTerminalID)
  }

  private func event(_ kind: AgentEventKind, at date: Date, preview: String? = nil) -> AgentEvent {
    AgentEvent(
      occurredAt: date,
      runID: "run",
      harness: .codex,
      kind: kind,
      ghosttyTerminalID: "terminal",
      processID: 123,
      cwd: "/tmp",
      promptPreview: preview
    )
  }
}

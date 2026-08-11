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

  func testRunListLimitsRecentsWhileKeepingAllActiveRuns() throws {
    let base = Date(timeIntervalSince1970: 1_700_000_000)
    for offset in 0..<3 {
      _ = try store.apply(
        AgentEvent(
          occurredAt: base.addingTimeInterval(TimeInterval(offset)),
          runID: "ended-\(offset)",
          harness: .codex,
          kind: .processExited
        ))
    }
    _ = try store.apply(
      AgentEvent(
        occurredAt: base.addingTimeInterval(10),
        runID: "active",
        harness: .claude,
        kind: .promptSubmitted
      ))

    let list = try store.runList(recentLimit: 2, includeRecentSince: .distantPast)

    XCTAssertEqual(list.recentCount, 3)
    XCTAssertEqual(list.runs.filter { $0.endedAt != nil }.map(\.runID), ["ended-2", "ended-1"])
    XCTAssertEqual(list.runs.filter { $0.endedAt == nil }.map(\.runID), ["active"])
    XCTAssertEqual(try store.activeRuns().map(\.runID), ["active"])
  }

  func testCursorHarnessWinsOverClaudeCompatibilityEvents() throws {
    let claude = AgentEvent(
      runID: "shared",
      harness: .claude,
      kind: .sessionStarted,
      harnessSessionID: "session",
      ghosttyTerminalID: "terminal",
      cwd: "/Users/example/.claude"
    )
    let cursor = AgentEvent(
      runID: "shared",
      harness: .cursor,
      kind: .promptSubmitted,
      harnessSessionID: "session",
      ghosttyTerminalID: "terminal",
      cwd: "/Users/example/project"
    )
    var laterClaude = claude
    laterClaude.eventID = UUID()
    laterClaude.kind = .turnStopped
    laterClaude.occurredAt = Date().addingTimeInterval(1)

    _ = try store.apply(claude)
    _ = try store.apply(cursor)
    _ = try store.apply(laterClaude)

    XCTAssertEqual(try store.run(id: "shared")?.harness, .cursor)
    XCTAssertEqual(try store.run(id: "shared")?.workingDirectory, "/Users/example/project")
    XCTAssertEqual(try store.run(id: "shared")?.status, .working)
  }

  func testClaudeCompatibilityActivityDoesNotClearCursorAttention() throws {
    let cursor = AgentEvent(
      runID: "shared",
      harness: .cursor,
      kind: .attentionRequired,
      harnessSessionID: "session",
      cwd: "/Users/example/project"
    )
    let compatibility = AgentEvent(
      occurredAt: cursor.occurredAt.addingTimeInterval(1),
      runID: "shared",
      harness: .claude,
      kind: .activity,
      harnessSessionID: "session",
      cwd: "/Users/example/.claude"
    )

    _ = try store.apply(cursor)
    _ = try store.apply(compatibility)

    XCTAssertEqual(try store.run(id: "shared")?.status, .needsAttention)
    XCTAssertEqual(try store.run(id: "shared")?.workingDirectory, "/Users/example/project")
  }

  func testLegacyHarnessQualifiedOrphansAreMergedOnOpen() throws {
    let sessionID = "legacy-session"
    _ = try store.apply(
      AgentEvent(
        runID: "orphan-claude-\(sessionID)",
        harness: .claude,
        kind: .promptSubmitted,
        harnessSessionID: sessionID,
        ghosttyTerminalID: "terminal",
        cwd: "/Users/example/.claude",
        promptPreview: "Fix it"
      ))
    _ = try store.apply(
      AgentEvent(
        runID: "orphan-cursor-\(sessionID)",
        harness: .cursor,
        kind: .promptSubmitted,
        harnessSessionID: sessionID,
        ghosttyTerminalID: "terminal",
        cwd: "/Users/example/.cursor",
        promptPreview: "Fix it"
      ))

    store = nil
    store = try RunStore(paths: AgentTrackerPaths(root: temporaryDirectory))

    let runs = try store.runs(includeRecentSince: .distantPast)
    XCTAssertEqual(runs.count, 1)
    XCTAssertEqual(runs.first?.runID, "orphan-\(sessionID)")
    XCTAssertEqual(runs.first?.harness, .cursor)
    XCTAssertEqual(runs.first?.workingDirectory, "/Users/example/.cursor")
    XCTAssertNil(try store.run(id: "orphan-claude-\(sessionID)"))
    XCTAssertNil(try store.run(id: "orphan-cursor-\(sessionID)"))
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

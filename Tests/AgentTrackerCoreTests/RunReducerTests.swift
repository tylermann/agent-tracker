import XCTest

@testable import AgentTrackerCore

/// Direct unit tests for the extracted run state machine (no database involved).
final class RunReducerTests: XCTestCase {
  private let base = Date(timeIntervalSince1970: 1_700_000_000)

  private func makeRun(_ status: RunStatus = .starting, harness: Harness = .claude) -> TrackedRun {
    TrackedRun(runID: "run", harness: harness, status: status, startedAt: base, lastEventAt: base)
  }

  private func event(
    _ kind: AgentEventKind, harness: Harness = .claude, at date: Date? = nil, cwd: String? = nil
  ) -> AgentEvent {
    AgentEvent(occurredAt: date ?? base, runID: "run", harness: harness, kind: kind, cwd: cwd)
  }

  func testStatusTransitions() {
    let table: [(RunStatus, AgentEventKind, RunStatus)] = [
      (.starting, .processStarted, .starting),
      (.ended, .sessionStarted, .starting),
      (.unavailable, .sessionStarted, .starting),
      (.working, .sessionStarted, .working),
      (.needsAttention, .sessionStarted, .needsAttention),
      (.starting, .promptSubmitted, .working),
      (.needsAttention, .activity, .working),
      (.working, .attentionRequired, .needsAttention),
      (.working, .turnStopped, .waiting),
      (.working, .sessionEnded, .ended),
      (.working, .processExited, .ended),
    ]
    for (initial, kind, expected) in table {
      var subject = makeRun(initial)
      RunReducer.reduce(event(kind), into: &subject)
      XCTAssertEqual(subject.status, expected, "\(initial) + \(kind) should be \(expected)")
    }
  }

  func testUnreadAttentionFollowsStatus() {
    var subject = makeRun()
    RunReducer.reduce(event(.attentionRequired), into: &subject)
    XCTAssertTrue(subject.unreadAttention)
    RunReducer.reduce(event(.activity), into: &subject)
    XCTAssertFalse(subject.unreadAttention)
    RunReducer.reduce(event(.turnStopped), into: &subject)
    XCTAssertTrue(subject.unreadAttention)
  }

  func testCursorRunIgnoresCompatibilityHarnessMetadataAndStatus() {
    var subject = makeRun(.needsAttention, harness: .cursor)
    subject.workingDirectory = "/project"
    RunReducer.reduce(
      event(.activity, harness: .claude, at: base.addingTimeInterval(1), cwd: "/tmp/.claude"),
      into: &subject)
    XCTAssertEqual(subject.harness, .cursor)
    XCTAssertEqual(subject.workingDirectory, "/project")
    XCTAssertEqual(subject.status, .needsAttention)
    // Timestamps and session metadata still advance from compatibility events.
    XCTAssertEqual(subject.lastEventAt, base.addingTimeInterval(1))
  }

  func testLastEventAtNeverMovesBackward() {
    var subject = makeRun()
    subject.lastEventAt = base.addingTimeInterval(10)
    RunReducer.reduce(event(.activity, at: base.addingTimeInterval(5)), into: &subject)
    XCTAssertEqual(subject.lastEventAt, base.addingTimeInterval(10))
  }
}

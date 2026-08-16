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
    var compatibility = event(
      .activity, harness: .claude, at: base.addingTimeInterval(1), cwd: "/tmp/.claude")
    compatibility.modelID = "claude-fable-5"
    RunReducer.reduce(compatibility, into: &subject)
    XCTAssertEqual(subject.harness, .cursor)
    XCTAssertEqual(subject.workingDirectory, "/project")
    XCTAssertNil(subject.modelID)
    XCTAssertEqual(subject.status, .needsAttention)
    // Timestamps and session metadata still advance from compatibility events.
    XCTAssertEqual(subject.lastEventAt, base.addingTimeInterval(1))
  }

  func testLatestAuthoritativeEventUpdatesModel() {
    var subject = makeRun(harness: .codex)
    var first = event(.processStarted, harness: .codex)
    first.modelID = "gpt-5.6-sol"
    RunReducer.reduce(first, into: &subject)
    XCTAssertEqual(subject.modelID, "gpt-5.6-sol")

    var switched = event(.activity, harness: .codex, at: base.addingTimeInterval(1))
    switched.modelID = "gpt-5.6-terra"
    RunReducer.reduce(switched, into: &subject)
    XCTAssertEqual(subject.modelID, "gpt-5.6-terra")
  }

  func testWorkingClockStartsOnceAndSurvivesToolActivity() {
    var subject = makeRun()
    RunReducer.reduce(event(.promptSubmitted, at: base), into: &subject)
    XCTAssertEqual(subject.workingSince, base)
    // Each tool call would previously have reset the visible timer.
    RunReducer.reduce(event(.activity, at: base.addingTimeInterval(30)), into: &subject)
    RunReducer.reduce(event(.activity, at: base.addingTimeInterval(90)), into: &subject)
    XCTAssertEqual(subject.workingSince, base)
    XCTAssertNil(subject.lastTurnDuration)
  }

  func testTurnDurationFreezesWhenTheRunComesBackToYou() {
    for kind in [AgentEventKind.turnStopped, .attentionRequired, .sessionEnded] {
      var subject = makeRun()
      RunReducer.reduce(event(.promptSubmitted, at: base), into: &subject)
      RunReducer.reduce(event(kind, at: base.addingTimeInterval(120)), into: &subject)
      XCTAssertEqual(subject.lastTurnDuration, 120, "\(kind) should freeze the turn length")
      XCTAssertNil(subject.workingSince, "\(kind) should stop the clock")
    }
  }

  func testApprovingAPermissionPromptStartsAFreshTurn() {
    var subject = makeRun()
    RunReducer.reduce(event(.promptSubmitted, at: base), into: &subject)
    RunReducer.reduce(event(.attentionRequired, at: base.addingTimeInterval(60)), into: &subject)
    // The user takes five minutes to approve; that wait belongs to nobody's run time.
    RunReducer.reduce(event(.activity, at: base.addingTimeInterval(360)), into: &subject)
    XCTAssertEqual(subject.workingSince, base.addingTimeInterval(360))
    RunReducer.reduce(event(.turnStopped, at: base.addingTimeInterval(400)), into: &subject)
    XCTAssertEqual(subject.lastTurnDuration, 40)
  }

  func testBlockedRunKeepsPreviousTurnLengthWhenAlreadyStopped() {
    var subject = makeRun()
    RunReducer.reduce(event(.promptSubmitted, at: base), into: &subject)
    RunReducer.reduce(event(.turnStopped, at: base.addingTimeInterval(45)), into: &subject)
    RunReducer.reduce(event(.attentionRequired, at: base.addingTimeInterval(300)), into: &subject)
    XCTAssertEqual(subject.lastTurnDuration, 45, "a second stop must not report a zero-length run")
  }

  func testRestartClearsTheWorkingClock() {
    var subject = makeRun()
    RunReducer.reduce(event(.promptSubmitted, at: base), into: &subject)
    RunReducer.reduce(event(.sessionStarted, at: base.addingTimeInterval(10)), into: &subject)
    XCTAssertNil(subject.workingSince)
  }

  func testLastEventAtNeverMovesBackward() {
    var subject = makeRun()
    subject.lastEventAt = base.addingTimeInterval(10)
    RunReducer.reduce(event(.activity, at: base.addingTimeInterval(5)), into: &subject)
    XCTAssertEqual(subject.lastEventAt, base.addingTimeInterval(10))
  }
}

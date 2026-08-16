import XCTest

@testable import AgentTrackerCore

final class ResumeCommandTests: XCTestCase {
  private func run(
    harness: Harness = .claude,
    sessionID: String? = "0195c9a2-2f2e-7c40-b0c5-2e9f2b2fd001",
    status: RunStatus = .ended
  ) -> TrackedRun {
    TrackedRun(runID: "run-1", harness: harness, harnessSessionID: sessionID, status: status)
  }

  func testClaudeResumeCommand() {
    XCTAssertEqual(
      ResumeCommand.command(for: run(harness: .claude, sessionID: "abc-123")),
      "claude --resume 'abc-123'"
    )
  }

  func testCodexResumeCommand() {
    XCTAssertEqual(
      ResumeCommand.command(for: run(harness: .codex, sessionID: "abc-123")),
      "codex resume 'abc-123'"
    )
  }

  func testCursorResumeCommandUsesAttachedFlagValue() {
    XCTAssertEqual(
      ResumeCommand.command(for: run(harness: .cursor, sessionID: "abc-123")),
      "agent --resume='abc-123'"
    )
  }

  func testSessionIDIsShellQuoted() {
    XCTAssertEqual(
      ResumeCommand.command(for: run(sessionID: "it's;$(id)")),
      "claude --resume 'it'\\''s;$(id)'"
    )
  }

  func testMissingOrEmptySessionIDHasNoCommand() {
    XCTAssertNil(ResumeCommand.command(for: run(sessionID: nil)))
    XCTAssertNil(ResumeCommand.command(for: run(sessionID: "")))
  }

  func testSessionIDWithWhitespaceOrControlCharactersHasNoCommand() {
    // The command is typed into a live terminal, where an embedded newline would submit a
    // truncated command line.
    XCTAssertNil(ResumeCommand.command(for: run(sessionID: "abc\ndef")))
    XCTAssertNil(ResumeCommand.command(for: run(sessionID: "abc def")))
    XCTAssertNil(ResumeCommand.command(for: run(sessionID: "abc\u{07}def")))
  }

  func testAvailabilityRequiresTerminalStatusAndSessionID() {
    XCTAssertTrue(ResumeCommand.isAvailable(for: run(status: .ended)))
    XCTAssertTrue(ResumeCommand.isAvailable(for: run(status: .unavailable)))
    XCTAssertFalse(ResumeCommand.isAvailable(for: run(status: .working)))
    XCTAssertFalse(ResumeCommand.isAvailable(for: run(status: .waiting)))
    XCTAssertFalse(ResumeCommand.isAvailable(for: run(sessionID: nil, status: .ended)))
  }
}

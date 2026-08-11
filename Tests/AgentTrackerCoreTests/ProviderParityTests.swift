import XCTest

@testable import AgentTrackerCore

/// Asserts that every hook event name the integration installer registers maps to the expected
/// event kind. The event lists are duplicated from IntegrationManager here; once the provider
/// registry exists, this test should read them from the registry instead so there is a single
/// source of truth.
final class ProviderParityTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_700_000_000)

  private let claudeEvents: [String: AgentEventKind] = [
    "SessionStart": .sessionStarted,
    "UserPromptSubmit": .promptSubmitted,
    "PermissionRequest": .attentionRequired,
    "Notification": .attentionRequired,
    "PreToolUse": .activity,
    "Stop": .turnStopped,
    "SessionEnd": .sessionEnded,
  ]

  private let codexEvents: [String: AgentEventKind] = [
    "SessionStart": .sessionStarted,
    "UserPromptSubmit": .promptSubmitted,
    "PermissionRequest": .attentionRequired,
    "PreToolUse": .activity,
    "Stop": .turnStopped,
    "SessionEnd": .sessionEnded,
  ]

  private let cursorEvents: [String: AgentEventKind] = [
    "sessionStart": .sessionStarted,
    "beforeSubmitPrompt": .promptSubmitted,
    "preToolUse": .activity,
    "postToolUse": .activity,
    "postToolUseFailure": .activity,
    "beforeShellExecution": .attentionRequired,
    "afterShellExecution": .activity,
    "beforeMCPExecution": .attentionRequired,
    "afterMCPExecution": .activity,
    "afterFileEdit": .activity,
    "stop": .turnStopped,
    "sessionEnd": .sessionEnded,
  ]

  func testEveryInstalledHookNameMapsToExpectedKind() throws {
    let table: [(Harness, [String: AgentEventKind])] = [
      (.claude, claudeEvents), (.codex, codexEvents), (.cursor, cursorEvents),
    ]
    for (harness, events) in table {
      for (eventName, expected) in events {
        let event = try EventMapper.map(
          harness: harness, eventName: eventName, payloadData: Data(), environment: [:], now: now)
        XCTAssertEqual(
          event?.kind, expected, "\(harness.rawValue) \(eventName) should map to \(expected)")
      }
    }
  }

  func testCodexPermissionRequestIsActivityUnderAutomaticReview() throws {
    let event = try EventMapper.map(
      harness: .codex,
      eventName: "PermissionRequest",
      payloadData: Data(),
      environment: ["AGENT_TRACKER_CODEX_AUTO_REVIEW": "1"],
      now: now
    )
    XCTAssertEqual(event?.kind, .activity)
  }
}

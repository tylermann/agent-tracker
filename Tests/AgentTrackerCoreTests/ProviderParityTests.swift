import XCTest

@testable import AgentTrackerCore

/// Asserts that every hook event name the integration installer registers maps to the expected
/// event kind. The installed names come straight from ProviderRegistry, so a provider spec that
/// registers an event this table does not anticipate fails the test.
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
    let expectations: [Harness: [String: AgentEventKind]] = [
      .claude: claudeEvents, .codex: codexEvents, .cursor: cursorEvents,
    ]
    for spec in ProviderRegistry.all {
      let table = try XCTUnwrap(expectations[spec.harness])
      XCTAssertEqual(
        Set(spec.hooks.events), Set(table.keys),
        "\(spec.harness.rawValue) installs an event this test does not anticipate")
      for eventName in spec.hooks.events {
        let expected = try XCTUnwrap(table[eventName])
        let event = try EventMapper.map(
          harness: spec.harness, eventName: eventName, payloadData: Data(), environment: [:],
          now: now)
        XCTAssertEqual(
          event?.kind, expected,
          "\(spec.harness.rawValue) \(eventName) should map to \(expected)")
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

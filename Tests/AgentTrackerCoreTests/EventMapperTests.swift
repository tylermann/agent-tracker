import XCTest

@testable import AgentTrackerCore

final class EventMapperTests: XCTestCase {
  func testCodexPromptMapsToWorkingEvent() throws {
    let payload = Data(
      #"{"session_id":"codex-1","cwd":"/tmp/project","prompt":"  Fix   the\nlogin flow  "}"#.utf8)
    let event = try XCTUnwrap(
      EventMapper.map(
        harness: .codex,
        eventName: "UserPromptSubmit",
        payloadData: payload,
        environment: [
          "AGENT_TRACKER_RUN_ID": "run-1",
          "AGENT_TRACKER_TERMINAL_ID": "terminal-1",
        ]
      ))
    XCTAssertEqual(event.kind, .promptSubmitted)
    XCTAssertEqual(event.runID, "run-1")
    XCTAssertEqual(event.harnessSessionID, "codex-1")
    XCTAssertEqual(event.ghosttyTerminalID, "terminal-1")
    XCTAssertEqual(event.promptPreview, "Fix the login flow")
  }

  func testClaudePermissionNotificationNeedsAttention() throws {
    let payload = Data(#"{"session_id":"claude-1","notification_type":"permission_prompt"}"#.utf8)
    let event = try XCTUnwrap(
      EventMapper.map(
        harness: .claude,
        eventName: "Notification",
        payloadData: payload,
        environment: ["AGENT_TRACKER_RUN_ID": "run-2"]
      ))
    XCTAssertEqual(event.kind, .attentionRequired)
  }

  func testNonAttentionClaudeNotificationIsIgnored() throws {
    let payload = Data(#"{"notification_type":"auth_success"}"#.utf8)
    XCTAssertNil(
      try EventMapper.map(
        harness: .claude,
        eventName: "Notification",
        payloadData: payload,
        environment: [:]
      ))
  }

  func testInputToolNeedsAttention() throws {
    let payload = Data(#"{"tool_name":"request_user_input"}"#.utf8)
    let event = try XCTUnwrap(
      EventMapper.map(
        harness: .cursor,
        eventName: "preToolUse",
        payloadData: payload,
        environment: ["AGENT_TRACKER_RUN_ID": "run-3"]
      ))
    XCTAssertEqual(event.kind, .attentionRequired)
  }

  func testCursorWebSearchNeedsAttentionAndUsesWorkspaceRoot() throws {
    let payload = Data(
      #"{"conversation_id":"cursor-1","workspace_roots":["/tmp/project"],"tool_name":"WebSearch"}"#
        .utf8)
    let event = try XCTUnwrap(
      EventMapper.map(
        harness: .cursor,
        eventName: "preToolUse",
        payloadData: payload,
        environment: ["PWD": "/Users/example/.claude"]
      ))

    XCTAssertEqual(event.kind, .attentionRequired)
    XCTAssertEqual(event.cwd, "/tmp/project")
  }

  func testCursorApprovalCompletionReturnsToActivity() throws {
    let event = try XCTUnwrap(
      EventMapper.map(
        harness: .cursor,
        eventName: "postToolUse",
        payloadData: Data(#"{"tool_name":"WebSearch"}"#.utf8),
        environment: [:]
      ))

    XCTAssertEqual(event.kind, .activity)
  }

  func testCursorShellAndMCPBeforeEventsNeedAttention() throws {
    for eventName in ["beforeShellExecution", "beforeMCPExecution"] {
      let event = try XCTUnwrap(
        EventMapper.map(
          harness: .cursor,
          eventName: eventName,
          payloadData: Data("{}".utf8),
          environment: [:]
        ))
      XCTAssertEqual(event.kind, .attentionRequired)
    }
  }

  func testCompatibleCursorAndClaudeHooksShareOrphanRunID() throws {
    let payload = Data(#"{"session_id":"shared-session"}"#.utf8)
    let cursor = try XCTUnwrap(
      EventMapper.map(
        harness: .cursor,
        eventName: "sessionStart",
        payloadData: payload,
        environment: [:]
      ))
    let claude = try XCTUnwrap(
      EventMapper.map(
        harness: .claude,
        eventName: "SessionStart",
        payloadData: payload,
        environment: [:]
      ))

    XCTAssertEqual(cursor.runID, "orphan-shared-session")
    XCTAssertEqual(claude.runID, cursor.runID)
  }

  func testPromptPreviewIsBounded() {
    let preview = EventMapper.promptPreview(String(repeating: "word ", count: 40))
    XCTAssertEqual(preview.count, 120)
    XCTAssertTrue(preview.hasSuffix("…"))
  }
}

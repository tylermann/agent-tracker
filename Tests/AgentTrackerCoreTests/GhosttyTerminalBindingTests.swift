import XCTest

@testable import AgentTrackerCore

final class GhosttyTerminalBindingTests: XCTestCase {
  func testCapturesFocusedTerminalForPromptFromGhostty() {
    let environment = GhosttyTerminalBinding.environmentByCapturingFocusedTerminal(
      for: "UserPromptSubmit",
      environment: ["TERM_PROGRAM": "ghostty"],
      focusedTerminalID: { "terminal-1" }
    )

    XCTAssertEqual(environment["AGENT_TRACKER_TERMINAL_ID"], "terminal-1")
  }

  func testCapturesFocusedTerminalForSessionStartFromGhostty() {
    let environment = GhosttyTerminalBinding.environmentByCapturingFocusedTerminal(
      for: "sessionStart",
      environment: ["TERM_PROGRAM": "Ghostty"],
      focusedTerminalID: { "terminal-2" }
    )

    XCTAssertEqual(environment["AGENT_TRACKER_TERMINAL_ID"], "terminal-2")
  }

  func testDoesNotGuessTerminalForAsynchronousEvent() {
    var resolverCalled = false
    let environment = GhosttyTerminalBinding.environmentByCapturingFocusedTerminal(
      for: "Stop",
      environment: ["TERM_PROGRAM": "ghostty"],
      focusedTerminalID: {
        resolverCalled = true
        return "wrong-terminal"
      }
    )

    XCTAssertNil(environment["AGENT_TRACKER_TERMINAL_ID"])
    XCTAssertFalse(resolverCalled)
  }

  func testPreservesWrapperTerminalBinding() {
    var resolverCalled = false
    let environment = GhosttyTerminalBinding.environmentByCapturingFocusedTerminal(
      for: "UserPromptSubmit",
      environment: [
        "TERM_PROGRAM": "ghostty",
        "AGENT_TRACKER_TERMINAL_ID": "wrapper-terminal",
      ],
      focusedTerminalID: {
        resolverCalled = true
        return "focused-terminal"
      }
    )

    XCTAssertEqual(environment["AGENT_TRACKER_TERMINAL_ID"], "wrapper-terminal")
    XCTAssertFalse(resolverCalled)
  }

  func testDoesNotBindSessionsOutsideGhostty() {
    let environment = GhosttyTerminalBinding.environmentByCapturingFocusedTerminal(
      for: "UserPromptSubmit",
      environment: ["TERM_PROGRAM": "Apple_Terminal"],
      focusedTerminalID: { "terminal-1" }
    )

    XCTAssertNil(environment["AGENT_TRACKER_TERMINAL_ID"])
  }
}

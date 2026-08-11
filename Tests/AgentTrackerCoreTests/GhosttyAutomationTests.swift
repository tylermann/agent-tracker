import XCTest

@testable import AgentTrackerCore

final class GhosttyAutomationTests: XCTestCase {
  func testFocusActivatesGhosttyAfterSelectingTerminal() throws {
    var scripts: [String] = []

    try GhosttyAutomation.focus(terminalID: "terminal-1") { source in
      scripts.append(source)
      return scripts.count == 1 ? "focused" : ""
    }

    XCTAssertEqual(scripts.count, 2)
    XCTAssertTrue(scripts[0].contains("focus candidate"))
    XCTAssertEqual(scripts[1], "tell application \"Ghostty\" to activate")
  }

  func testFocusDoesNotActivateGhosttyWhenTerminalIsMissing() throws {
    var scripts: [String] = []

    XCTAssertThrowsError(
      try GhosttyAutomation.focus(terminalID: "missing") { source in
        scripts.append(source)
        return "missing"
      }
    ) { error in
      guard case GhosttyAutomationError.terminalNotFound = error else {
        return XCTFail("Expected terminalNotFound, got \(error)")
      }
    }

    XCTAssertEqual(scripts.count, 1)
  }
}

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

  func testFocusSelectsOwningTabAndUnzoomsItWhenTargetTerminalIsDetached() throws {
    var scripts: [String] = []

    try GhosttyAutomation.focus(terminalID: "terminal-1") { source in
      scripts.append(source)
      switch scripts.count {
      case 1:
        throw GhosttyAutomationError.script("Terminal is not in a window.")
      case 2:
        return "focused"
      default:
        return ""
      }
    }

    XCTAssertEqual(scripts.count, 3)
    XCTAssertTrue(scripts[1].contains("repeat with candidateWindow in windows"))
    XCTAssertTrue(scripts[1].contains("repeat with candidateTab in tabs of candidateWindow"))
    XCTAssertTrue(scripts[1].contains("repeat with candidate in terminals of candidateTab"))
    XCTAssertTrue(scripts[1].contains("select tab (contents of candidateTab)"))
    XCTAssertTrue(scripts[1].contains("activate window candidateWindow"))
    XCTAssertTrue(scripts[1].contains("set focusedTabTerminal to focused terminal of candidateTab"))
    XCTAssertTrue(
      scripts[1].contains("perform action \"toggle_split_zoom\" on focusedTabTerminal"))
    XCTAssertTrue(scripts[1].contains("repeat with attempt from 1 to 30"))
    XCTAssertTrue(scripts[1].contains("delay 0.1"))
    XCTAssertTrue(scripts[1].contains("focus (contents of candidate)"))
    XCTAssertEqual(scripts[2], "tell application \"Ghostty\" to activate")
  }

  func testFocusDoesNotRecoverFromUnrelatedAutomationError() throws {
    var scripts: [String] = []

    XCTAssertThrowsError(
      try GhosttyAutomation.focus(terminalID: "terminal-1") { source in
        scripts.append(source)
        throw GhosttyAutomationError.script("Not authorized to send Apple events.")
      }
    ) { error in
      guard case GhosttyAutomationError.script(let message) = error else {
        return XCTFail("Expected script error, got \(error)")
      }
      XCTAssertEqual(message, "Not authorized to send Apple events.")
    }

    XCTAssertEqual(scripts.count, 1)
  }

  func testFocusPropagatesRecoveryScriptFailure() throws {
    var scripts: [String] = []

    XCTAssertThrowsError(
      try GhosttyAutomation.focus(terminalID: "terminal-1") { source in
        scripts.append(source)
        if scripts.count == 1 {
          throw GhosttyAutomationError.script("Terminal is not in a window.")
        }
        throw GhosttyAutomationError.script("Split zoom action failed.")
      }
    ) { error in
      guard case GhosttyAutomationError.script(let message) = error else {
        return XCTFail("Expected script error, got \(error)")
      }
      XCTAssertEqual(message, "Split zoom action failed.")
    }

    XCTAssertEqual(scripts.count, 2)
  }

  func testOpenTabTypesCommandIntoNewSurfaceInWorkingDirectory() throws {
    var scripts: [String] = []

    try GhosttyAutomation.openTab(
      command: "codex resume 'abc-123'",
      workingDirectory: "/Users/me/project"
    ) { source in
      scripts.append(source)
      return ""
    }

    XCTAssertEqual(scripts.count, 1)
    let script = scripts[0]
    XCTAssertTrue(script.contains("if (count of windows) is 0"))
    XCTAssertTrue(script.contains("new window with configuration"))
    XCTAssertTrue(script.contains("new tab in front window with configuration"))
    XCTAssertTrue(script.contains("initial working directory:\"/Users/me/project\""))
    XCTAssertTrue(script.contains("initial input:(\"codex resume 'abc-123'\" & return)"))
    XCTAssertTrue(script.contains("activate"))
  }

  func testOpenTabOmitsWorkingDirectoryWhenUnknown() throws {
    var scripts: [String] = []

    try GhosttyAutomation.openTab(command: "claude --resume 'abc'", workingDirectory: nil) {
      source in
      scripts.append(source)
      return ""
    }

    XCTAssertEqual(scripts.count, 1)
    XCTAssertFalse(scripts[0].contains("initial working directory"))
  }

  func testOpenTabEscapesAppleScriptStringContent() throws {
    var scripts: [String] = []

    try GhosttyAutomation.openTab(
      command: "claude --resume 'a\"b'",
      workingDirectory: "/Users/me/\"quoted\" dir"
    ) { source in
      scripts.append(source)
      return ""
    }

    XCTAssertEqual(scripts.count, 1)
    XCTAssertTrue(scripts[0].contains("initial working directory:\"/Users/me/\\\"quoted\\\" dir\""))
    XCTAssertTrue(scripts[0].contains("initial input:(\"claude --resume 'a\\\"b'\" & return)"))
  }

  func testOpenTabPropagatesScriptFailure() {
    XCTAssertThrowsError(
      try GhosttyAutomation.openTab(command: "codex resume 'abc'", workingDirectory: nil) { _ in
        throw GhosttyAutomationError.script("Not authorized to send Apple events.")
      }
    ) { error in
      guard case GhosttyAutomationError.script(let message) = error else {
        return XCTFail("Expected script error, got \(error)")
      }
      XCTAssertEqual(message, "Not authorized to send Apple events.")
    }
  }

  func testFocusDoesNotActivateGhosttyWhenDetachedTerminalIsMissingFromWindows() throws {
    var scripts: [String] = []

    XCTAssertThrowsError(
      try GhosttyAutomation.focus(terminalID: "terminal-1") { source in
        scripts.append(source)
        switch scripts.count {
        case 1:
          throw GhosttyAutomationError.script("Terminal is not in a window.")
        default:
          return "missing"
        }
      }
    ) { error in
      guard case GhosttyAutomationError.terminalNotFound = error else {
        return XCTFail("Expected terminalNotFound, got \(error)")
      }
    }

    XCTAssertEqual(scripts.count, 2)
  }
}

import AppKit
import Foundation

public enum GhosttyAutomationError: LocalizedError {
  case script(String)
  case noFocusedTerminal
  case terminalNotFound

  public var errorDescription: String? {
    switch self {
    case .script(let message): "Ghostty automation failed: \(message)"
    case .noFocusedTerminal: "Ghostty has no focused terminal."
    case .terminalNotFound: "The tracked Ghostty terminal is no longer open."
    }
  }
}

public enum GhosttyAutomation {
  private static let detachedTerminalError = "Terminal is not in a window."

  public static func focusedTerminalID() throws -> String {
    let source = """
      tell application "Ghostty"
          if not running then return ""
          if (count of windows) is 0 then return ""
          set currentTerminal to focused terminal of selected tab of front window
          return id of currentTerminal
      end tell
      """
    let value = try run(source).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { throw GhosttyAutomationError.noFocusedTerminal }
    return value
  }

  public static func focus(terminalID: String) throws {
    try focus(terminalID: terminalID, runScript: run)
  }

  static func focus(
    terminalID: String,
    runScript: (String) throws -> String
  ) throws {
    let escaped = appleScriptString(terminalID)
    let source = """
      tell application "Ghostty"
          repeat with candidate in terminals
              if id of candidate is "\(escaped)" then
                  focus candidate
                  return "focused"
              end if
          end repeat
          return "missing"
      end tell
      """
    do {
      guard try runScript(source) == "focused" else {
        throw GhosttyAutomationError.terminalNotFound
      }
    } catch GhosttyAutomationError.script(let message)
      where message.contains(detachedTerminalError)
    {
      try focusAfterActivatingOwningWindow(terminalID: escaped, runScript: runScript)
    }

    // A nonactivating Agent Tracker panel can remain the key window after its button is
    // clicked. Activate Ghostty only after selecting the terminal so its input surface gets
    // keyboard focus and the user can type immediately.
    _ = try runScript("tell application \"Ghostty\" to activate")
  }

  private static func focusAfterActivatingOwningWindow(
    terminalID: String,
    runScript: (String) throws -> String
  ) throws {
    // Ghostty keeps split-zoom state per tab and detaches the other terminal views in that tab.
    // After selecting the target tab, try focusing first; if the target is still detached, unzoom
    // that tab's focused split as well before retrying.
    let source = """
      tell application "Ghostty"
          repeat with candidateWindow in windows
              repeat with candidateTab in tabs of candidateWindow
                  repeat with candidate in terminals of candidateTab
                      if id of candidate is "\(terminalID)" then
                          select tab (contents of candidateTab)
                          activate window candidateWindow
                          try
                              focus (contents of candidate)
                              return "focused"
                          on error messageText
                              if messageText does not contain "\(detachedTerminalError)" then error messageText
                          end try
                          set focusedTabTerminal to focused terminal of candidateTab
                          if id of focusedTabTerminal is not "\(terminalID)" then
                              perform action "toggle_split_zoom" on focusedTabTerminal
                          end if
                          repeat with attempt from 1 to 30
                              try
                                  select tab (contents of candidateTab)
                                  activate window candidateWindow
                                  focus (contents of candidate)
                                  return "focused"
                              on error messageText
                                  if messageText does not contain "\(detachedTerminalError)" then error messageText
                                  delay 0.1
                              end try
                          end repeat
                          focus (contents of candidate)
                          return "focused"
                      end if
                  end repeat
              end repeat
          end repeat
          return "missing"
      end tell
      """
    guard try runScript(source) == "focused" else {
      throw GhosttyAutomationError.terminalNotFound
    }
  }

  /// Opens a new terminal in `workingDirectory` and types `command` into its shell. Typing the
  /// command (instead of launching it as the surface's command) keeps the surface on the user's
  /// interactive zsh, so the managed wrapper functions run and the new session is tracked.
  public static func openTab(command: String, workingDirectory: String?) throws {
    try openTab(command: command, workingDirectory: workingDirectory, runScript: run)
  }

  static func openTab(
    command: String,
    workingDirectory: String?,
    runScript: (String) throws -> String
  ) throws {
    var fields = [String]()
    if let workingDirectory, !workingDirectory.isEmpty {
      fields.append("initial working directory:\"\(appleScriptString(workingDirectory))\"")
    }
    fields.append("initial input:(\"\(appleScriptString(command))\" & return)")
    let configuration = "{\(fields.joined(separator: ", "))}"
    let source = """
      tell application "Ghostty"
          if (count of windows) is 0 then
              new window with configuration \(configuration)
          else
              new tab in front window with configuration \(configuration)
          end if
          activate
      end tell
      """
    _ = try runScript(source)
  }

  public static func isFocused(terminalID: String) -> Bool {
    guard isFrontmost, (try? focusedTerminalID()) == terminalID else { return false }
    return true
  }

  /// Reading Ghostty's front window while another app is active would make the sidebar highlight a
  /// terminal the user is not actually looking at. Keep that frontmost check shared with callers
  /// that resolve the current terminal once and map it to a tracked run.
  public static var isFrontmost: Bool {
    guard let frontmost = NSWorkspace.shared.frontmostApplication else { return false }
    return frontmost.bundleIdentifier == "com.mitchellh.ghostty"
      || frontmost.localizedName == "Ghostty"
  }

  public static func ghosttyVersion() -> String? {
    try? run("tell application \"Ghostty\" to return version")
  }

  private static func run(_ source: String) throws -> String {
    guard let script = NSAppleScript(source: source) else {
      throw GhosttyAutomationError.script("could not compile AppleScript")
    }
    var details: NSDictionary?
    let result = script.executeAndReturnError(&details)
    if let details {
      let message = details[NSAppleScript.errorMessage] as? String ?? details.description
      throw GhosttyAutomationError.script(message)
    }
    return result.stringValue ?? ""
  }

  private static func appleScriptString(_ value: String) -> String {
    value.replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
  }
}

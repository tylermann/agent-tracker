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
    guard try run(source) == "focused" else {
      throw GhosttyAutomationError.terminalNotFound
    }
  }

  public static func isFocused(terminalID: String) -> Bool {
    guard (try? focusedTerminalID()) == terminalID,
      let frontmost = NSWorkspace.shared.frontmostApplication
    else { return false }
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

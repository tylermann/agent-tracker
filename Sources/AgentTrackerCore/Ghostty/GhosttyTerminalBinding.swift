import Foundation

public enum GhosttyTerminalBinding {
  public static func environmentByCapturingFocusedTerminal(
    for eventName: String,
    environment: [String: String],
    focusedTerminalID: () throws -> String = GhosttyAutomation.focusedTerminalID
  ) -> [String: String] {
    guard environment["AGENT_TRACKER_TERMINAL_ID"] == nil,
      environment["TERM_PROGRAM"]?.lowercased() == "ghostty",
      isUserInitiated(eventName)
    else { return environment }

    guard let terminalID = try? focusedTerminalID(), !terminalID.isEmpty else {
      return environment
    }
    var enriched = environment
    enriched["AGENT_TRACKER_TERMINAL_ID"] = terminalID
    return enriched
  }

  private static func isUserInitiated(_ eventName: String) -> Bool {
    let normalized = eventName.replacingOccurrences(
      of: "[^a-zA-Z]",
      with: "",
      options: .regularExpression
    ).lowercased()
    return normalized == "sessionstart"
      || normalized == "userpromptsubmit"
      || normalized == "beforesubmitprompt"
  }
}

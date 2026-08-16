import Foundation

/// Builds the shell command that reopens a finished run's recorded harness session. Commands are
/// typed into a fresh interactive shell rather than executed directly, so the provider name
/// resolves through the managed zsh wrappers and the resumed session is tracked like any other.
public enum ResumeCommand {
  public static func command(for run: TrackedRun) -> String? {
    guard let sessionID = usableSessionID(run.harnessSessionID) else { return nil }
    let quoted = ShellQuoting.quote(sessionID)
    switch run.harness {
    case .claude: return "claude --resume \(quoted)"
    case .codex: return "codex resume \(quoted)"
    // Cursor's `--resume` takes an optional value; the `=` form keeps the chat ID attached to
    // the flag instead of being read as an initial prompt.
    case .cursor: return "agent --resume=\(quoted)"
    }
  }

  /// Whether the sidebar should offer to resume this run: its session is over and it recorded
  /// enough to relaunch.
  public static func isAvailable(for run: TrackedRun) -> Bool {
    (run.status == .ended || run.status == .unavailable) && command(for: run) != nil
  }

  /// The resume command is sent to a live terminal, so a session ID containing a newline would
  /// submit a truncated command. Session IDs are UUID-like for every provider; reject anything
  /// with whitespace outright rather than trying to repair it.
  private static func usableSessionID(_ raw: String?) -> String? {
    guard let raw, !raw.isEmpty,
      raw.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
      raw.rangeOfCharacter(from: .controlCharacters) == nil
    else { return nil }
    return raw
  }
}

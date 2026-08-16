import Foundation

/// Finds the on-disk transcript a harness writes for a given session.
///
/// Both supported harnesses bury the file under a directory layout derived from something we do
/// not store (Claude slugs the working directory; Codex dates the file), so both are located by
/// searching for the session ID rather than by reconstructing the path. Results are cached by the
/// caller — this is the slow path, run once per run.
enum TranscriptLocator {
  static func url(
    harness: Harness,
    sessionID: String,
    home: URL = FileManager.default.homeDirectoryForCurrentUser,
    fileManager: FileManager = .default
  ) -> URL? {
    guard !sessionID.isEmpty else { return nil }
    switch harness {
    case .claude:
      return claudeURL(sessionID: sessionID, home: home, fileManager: fileManager)
    case .codex:
      return codexURL(sessionID: sessionID, home: home, fileManager: fileManager)
    case .cursor:
      // Recent Cursor versions write JSONL transcripts too, but those still omit token counts.
      // Live Cursor context arrives through its status-line callback and bypasses this locator.
      return nil
    }
  }

  /// `~/.claude/projects/<slugified-cwd>/<session-id>.jsonl`. The slug rules are Claude's, so the
  /// project directories are scanned for the session file instead of being reconstructed.
  private static func claudeURL(sessionID: String, home: URL, fileManager: FileManager) -> URL? {
    let projects = home.appendingPathComponent(".claude/projects", isDirectory: true)
    guard
      let directories = try? fileManager.contentsOfDirectory(
        at: projects,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
      )
    else { return nil }
    let candidates = directories.map { $0.appendingPathComponent("\(sessionID).jsonl") }
    return candidates.first { fileManager.fileExists(atPath: $0.path) }
  }

  /// `~/.codex/sessions/YYYY/MM/DD/rollout-<timestamp>-<session-id>.jsonl`. Walked newest-first:
  /// a session being tracked is nearly always today's or yesterday's, so the match is found in the
  /// first directory or two rather than after a full traversal of the archive.
  private static func codexURL(sessionID: String, home: URL, fileManager: FileManager) -> URL? {
    let sessions = home.appendingPathComponent(".codex/sessions", isDirectory: true)
    let suffix = "-\(sessionID).jsonl"
    for year in descendingChildren(of: sessions, fileManager: fileManager) {
      for month in descendingChildren(of: year, fileManager: fileManager) {
        for day in descendingChildren(of: month, fileManager: fileManager) {
          let match = descendingChildren(of: day, fileManager: fileManager)
            .first { $0.lastPathComponent.hasSuffix(suffix) }
          if let match { return match }
        }
      }
    }
    return nil
  }

  private static func descendingChildren(of directory: URL, fileManager: FileManager) -> [URL] {
    let children =
      (try? fileManager.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles]
      )) ?? []
    return children.sorted { $0.lastPathComponent > $1.lastPathComponent }
  }
}

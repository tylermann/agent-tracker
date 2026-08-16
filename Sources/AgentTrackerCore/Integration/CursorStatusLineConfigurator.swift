import Foundation

/// Claims Cursor CLI's optional status-line command only when that single slot is unused. Existing
/// user status lines are left byte-for-byte alone; those installations still receive less precise
/// end-of-turn context through Cursor's Stop hook.
struct CursorStatusLineConfigurator {
  enum InstallResult: Equatable {
    case installed
    case alreadyInstalled
    case skippedExisting
  }

  let home: URL
  let fileManager: FileManager
  let marker: String

  private var url: URL { home.appendingPathComponent(".cursor/cli-config.json") }

  func install(helperPath: String) throws -> InstallResult {
    var root = try jsonObject()
    if let rawExisting = root["statusLine"] {
      guard var existing = rawExisting as? [String: Any] else { return .skippedExisting }
      let command = existing["command"] as? String ?? ""
      guard command.contains(marker) else { return .skippedExisting }
      existing["type"] = "command"
      existing["command"] = managedCommand(helperPath: helperPath)
      root["statusLine"] = existing
      try writeJSON(root, backup: false)
      return .alreadyInstalled
    }
    root["statusLine"] = [
      "type": "command",
      "command": managedCommand(helperPath: helperPath),
      "padding": 0,
    ]
    try writeJSON(root, backup: true)
    return .installed
  }

  func uninstall() throws {
    guard fileManager.fileExists(atPath: url.path) else { return }
    var root = try jsonObject()
    guard let existing = root["statusLine"] as? [String: Any],
      let command = existing["command"] as? String, command.contains(marker)
    else { return }
    root.removeValue(forKey: "statusLine")
    try writeJSON(root, backup: false)
  }

  private func managedCommand(helperPath: String) -> String {
    "\(ShellQuoting.quote(helperPath)) cursor-context --source agent-tracker"
  }

  private func jsonObject() throws -> [String: Any] {
    guard fileManager.fileExists(atPath: url.path) else { return [:] }
    let data = try Data(contentsOf: url)
    guard !data.isEmpty else { return [:] }
    return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
  }

  private func writeJSON(_ object: [String: Any], backup: Bool) throws {
    var data = try JSONSerialization.data(
      withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    data.append(0x0A)
    try AtomicFileWriter.write(
      data, to: url, permissions: 0o600, backup: backup, fileManager: fileManager)
  }
}

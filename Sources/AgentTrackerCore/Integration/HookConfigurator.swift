import Foundation

/// Merges Agent Tracker's hook commands into a provider's configuration file, and removes them,
/// without disturbing entries the user added themselves. The provider's `HookInstallation`
/// supplies the file path, event names, and entry shape.
struct HookConfigurator {
  let home: URL
  let fileManager: FileManager
  /// Substring identifying commands owned by Agent Tracker inside provider hook files. Uninstall
  /// removes any entry containing it.
  let marker: String

  func merge(_ spec: ProviderSpec, helperPath: String) throws {
    let url = home.appendingPathComponent(spec.hooks.configPath)
    var root = try jsonObject(at: url)
    for (key, value) in spec.hooks.rootDefaults {
      root[key] = root[key] ?? value
    }
    var hooks = root["hooks"] as? [String: Any] ?? [:]
    for event in spec.hooks.events {
      var entries = hooks[event] as? [[String: Any]] ?? []
      let command = hookCommand(helperPath: helperPath, harness: spec.harness, event: event)
      switch spec.hooks.style {
      case .nestedMatcherGroups:
        entries = removingNestedManagedCommands(from: entries)
        entries.append([
          "matcher": "",
          "hooks": [["type": "command", "command": command, "timeout": 5]],
        ])
      case .flatEntries:
        entries.removeAll(where: containsMarker)
        entries.append(["command": command, "timeout": 5])
      }
      hooks[event] = entries
    }
    root["hooks"] = hooks
    try writeJSON(root, to: url)
  }

  func remove(_ spec: ProviderSpec) throws {
    let url = home.appendingPathComponent(spec.hooks.configPath)
    guard fileManager.fileExists(atPath: url.path) else { return }
    var root = try jsonObject(at: url)
    guard var hooks = root["hooks"] as? [String: Any] else { return }
    for (event, value) in hooks {
      guard let entries = value as? [[String: Any]] else { continue }
      let kept: [[String: Any]]
      switch spec.hooks.style {
      case .nestedMatcherGroups:
        kept = removingNestedManagedCommands(from: entries)
      case .flatEntries:
        kept = entries.filter { !containsMarker($0) }
      }
      if kept.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = kept }
    }
    root["hooks"] = hooks
    try writeJSON(root, to: url, backup: false)
  }

  private func hookCommand(helperPath: String, harness: Harness, event: String) -> String {
    "\(ShellQuoting.quote(helperPath)) event --source agent-tracker --harness \(harness.rawValue) --event \(event)"
  }

  private func removingNestedManagedCommands(from entries: [[String: Any]]) -> [[String: Any]] {
    var kept: [[String: Any]] = []
    for var entry in entries {
      guard let commands = entry["hooks"] as? [[String: Any]] else {
        if !containsMarker(entry) { kept.append(entry) }
        continue
      }
      let remaining = commands.filter { !containsMarker($0) }
      if !remaining.isEmpty {
        entry["hooks"] = remaining
        kept.append(entry)
      }
    }
    return kept
  }

  private func containsMarker(_ value: Any) -> Bool {
    if let string = value as? String { return string.contains(marker) }
    if let dictionary = value as? [String: Any] {
      return dictionary.values.contains(where: containsMarker)
    }
    if let array = value as? [Any] { return array.contains(where: containsMarker) }
    return false
  }

  private func jsonObject(at url: URL) throws -> [String: Any] {
    guard fileManager.fileExists(atPath: url.path) else { return [:] }
    let data = try Data(contentsOf: url)
    guard !data.isEmpty else { return [:] }
    return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
  }

  private func writeJSON(_ object: [String: Any], to url: URL, backup: Bool = true) throws {
    let data = try JSONSerialization.data(
      withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    var terminated = data
    terminated.append(0x0A)
    try AtomicFileWriter.write(
      terminated, to: url, permissions: 0o600, backup: backup, fileManager: fileManager)
  }
}

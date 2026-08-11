import Foundation

public enum CodexConfiguration {
  /// Whether Codex delegates approval decisions to its automatic reviewer.
  ///
  /// PermissionRequest hooks run before that reviewer has made its decision, so callers use this
  /// to avoid presenting the in-progress review itself as a request for the user's attention.
  public static func usesAutomaticApprovalReview(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> Bool {
    let codexHome: URL
    if let configuredHome = environment["CODEX_HOME"], !configuredHome.isEmpty {
      codexHome = URL(fileURLWithPath: configuredHome, isDirectory: true)
    } else {
      codexHome = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
        ".codex", isDirectory: true)
    }

    guard let configuration = try? String(
      contentsOf: codexHome.appendingPathComponent("config.toml"), encoding: .utf8)
    else {
      return false
    }
    return usesAutomaticApprovalReview(configuration: configuration)
  }

  static func usesAutomaticApprovalReview(configuration: String) -> Bool {
    let pattern = #"(?m)^\s*approvals_reviewer\s*=\s*\"([^\"]+)\""#
    guard let expression = try? NSRegularExpression(pattern: pattern),
      let match = expression.firstMatch(
        in: configuration,
        range: NSRange(configuration.startIndex..., in: configuration)
      ),
      let valueRange = Range(match.range(at: 1), in: configuration)
    else {
      return false
    }
    return configuration[valueRange].lowercased() == "auto_review"
  }
}

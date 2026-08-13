import Foundation

enum CodexProvider {
  static let spec = ProviderSpec(
    harness: .codex,
    resolutionExecutableName: "codex",
    wrapperFunctionNames: ["codex"],
    hooks: HookInstallation(
      configPath: ".codex/hooks.json",
      events: [
        "SessionStart", "UserPromptSubmit", "PermissionRequest", "PreToolUse", "Stop", "SessionEnd",
      ],
      style: .nestedMatcherGroups,
      // Codex caps SessionEnd at 3s and warns if the configured timeout is higher.
      eventTimeouts: ["SessionEnd": 3],
      installReportLine: "Installed Codex lifecycle hooks without changing config.toml or notify.",
      removeReportLine: "Removed Agent Tracker Codex hooks."
    ),
    usage: UsageSpec(
      readCredential: readCredential(home:allowKeychainPrompt:),
      request: usageRequest(for:),
      parse: parseUsage(_:fetchedAt:)
    ),
    logoResourceName: "codex",
    enrichHookEnvironment: { _, environment in
      var environment = environment
      if CodexConfiguration.usesAutomaticApprovalReview(environment: environment) {
        environment["AGENT_TRACKER_CODEX_AUTO_REVIEW"] = "1"
      }
      return environment
    },
    emitsJSONAckForStopEvents: true
  )

  static func parseUsage(_ data: Data, fetchedAt: Date) throws -> ProviderUsageSnapshot {
    let root = try UsageParsing.dictionary(data)
    let limits = (root["rate_limit"] ?? root["rateLimits"]) as? [String: Any] ?? [:]
    let primary = window(
      limits["primary_window"] ?? limits["primary"],
      fallbackLabel: "Usage"
    )
    let secondary = window(
      limits["secondary_window"] ?? limits["secondary"],
      fallbackLabel: "Secondary"
    )
    guard primary != nil || secondary != nil else { throw UsageParseError.missingUsage }
    return ProviderUsageSnapshot(
      harness: .codex,
      primary: primary ?? secondary,
      secondary: primary == nil ? nil : secondary,
      fetchedAt: fetchedAt
    )
  }

  static func readCredential(home: URL, allowKeychainPrompt: Bool) throws -> UsageCredential {
    let file = home.appendingPathComponent(".codex/auth.json")
    if let root = CredentialReading.json(at: file), let credential = credential(root) {
      return credential
    }
    #if canImport(Security)
      // Codex uses this service when cli_auth_credentials_store is `keyring` or `auto`.
      if let data = CredentialReading.keychainPassword(
        service: "Codex Auth", allowPrompt: allowKeychainPrompt),
        let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let credential = credential(root)
      {
        return credential
      }
    #endif
    throw CredentialReading.loggedOutError(allowKeychainPrompt: allowKeychainPrompt)
  }

  static func usageRequest(for credential: UsageCredential) -> URLRequest {
    var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
    request.timeoutInterval = 15
    request.cachePolicy = .reloadIgnoringLocalCacheData
    request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("codex-cli", forHTTPHeaderField: "User-Agent")
    if let accountID = credential.accountID {
      request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
    }
    return request
  }

  private static func credential(_ root: [String: Any]) -> UsageCredential? {
    guard let tokens = root["tokens"] as? [String: Any],
      let token = CredentialReading.nonempty(tokens["access_token"])
    else { return nil }
    return UsageCredential(
      accessToken: token, accountID: CredentialReading.nonempty(tokens["account_id"]))
  }

  private static func window(_ raw: Any?, fallbackLabel: String) -> UsageWindow? {
    guard let value = raw as? [String: Any] else { return nil }
    let seconds =
      UsageParsing.number(value["limit_window_seconds"] ?? value["window_seconds"])
      ?? UsageParsing.number(value["limit_window_minutes"] ?? value["window_minutes"])
      .map { $0 * 60 }
    return UsageParsing.window(
      value,
      label: seconds.map(windowLabel) ?? fallbackLabel,
      usedKeys: ["used_percent", "usedPercent"]
    )
  }

  private static func windowLabel(seconds: Double) -> String {
    let hours = seconds / 3_600
    if abs(hours - 168) < 0.1 { return "Week" }
    if hours >= 24, abs(hours.rounded() - hours) < 0.1 {
      return "\(Int(hours.rounded() / 24))d"
    }
    if hours >= 1, abs(hours.rounded() - hours) < 0.1 {
      return "\(Int(hours.rounded()))h"
    }
    let minutes = max(1, Int((seconds / 60).rounded()))
    return "\(minutes)m"
  }
}

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

    guard
      let configuration = try? String(
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

import Foundation

enum ClaudeProvider {
  static let spec = ProviderSpec(
    harness: .claude,
    resolutionExecutableName: "claude",
    wrapperFunctionNames: ["claude"],
    hooks: HookInstallation(
      configPath: ".claude/settings.json",
      events: [
        "SessionStart", "UserPromptSubmit", "PermissionRequest", "Notification", "PreToolUse",
        "Stop", "SessionEnd",
      ],
      style: .nestedMatcherGroups,
      installReportLine: "Installed Claude lifecycle hooks.",
      removeReportLine: "Removed Agent Tracker Claude hooks."
    ),
    usage: UsageSpec(
      readCredential: readCredential(home:allowKeychainPrompt:),
      request: usageRequest(for:),
      parse: parseUsage(_:fetchedAt:)
    ),
    logoResourceName: "claude"
  )

  static func parseUsage(_ data: Data, fetchedAt: Date) throws -> ProviderUsageSnapshot {
    let root = try UsageParsing.dictionary(data)
    guard let primary = UsageParsing.window(root["five_hour"], label: "5h") else {
      throw UsageParseError.missingUsage
    }
    let secondary = UsageParsing.window(root["seven_day"], label: "Week")
    let modelSpecific = modelWindow(root)
    var overage: UsageOverage?
    if let value = root["extra_usage"] as? [String: Any] {
      overage = UsageOverage(
        isEnabled: UsageParsing.bool(value["is_enabled"]) ?? false,
        usedPercent: UsageParsing.number(value["utilization"]),
        usedAmount: UsageParsing.number(value["used_credits"]),
        limitAmount: UsageParsing.number(value["monthly_limit"]),
        unit: "credits"
      )
    }
    return ProviderUsageSnapshot(
      harness: .claude,
      primary: primary,
      secondary: secondary,
      modelSpecific: modelSpecific,
      overage: overage,
      fetchedAt: fetchedAt
    )
  }

  static func readCredential(home: URL, allowKeychainPrompt: Bool) throws -> UsageCredential {
    let file = home.appendingPathComponent(".claude/.credentials.json")
    if let root = CredentialReading.json(at: file),
      let oauth = root["claudeAiOauth"] as? [String: Any],
      let token = CredentialReading.nonempty(oauth["accessToken"])
    {
      return UsageCredential(accessToken: token)
    }
    #if canImport(Security)
      for service in ["Claude Code-credentials", "claude-code-credentials"] {
        if let data = CredentialReading.keychainPassword(
          service: service, allowPrompt: allowKeychainPrompt),
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let oauth = root["claudeAiOauth"] as? [String: Any],
          let token = CredentialReading.nonempty(oauth["accessToken"])
        {
          return UsageCredential(accessToken: token)
        }
      }
    #endif
    throw CredentialReading.loggedOutError(allowKeychainPrompt: allowKeychainPrompt)
  }

  static func usageRequest(for credential: UsageCredential) -> URLRequest {
    var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
    request.timeoutInterval = 15
    request.cachePolicy = .reloadIgnoringLocalCacheData
    request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
    request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("claude-code/agent-tracker", forHTTPHeaderField: "User-Agent")
    return request
  }

  private static func modelWindow(_ root: [String: Any]) -> UsageWindow? {
    let candidates = root.keys.filter { $0.hasPrefix("seven_day_") }
    let ordered = candidates.sorted { left, right in
      func rank(_ value: String) -> Int {
        if value.localizedCaseInsensitiveContains("fable") { return 0 }
        if value.localizedCaseInsensitiveContains("sonnet") { return 1 }
        if value.localizedCaseInsensitiveContains("opus") { return 2 }
        return 3
      }
      let ranks = (rank(left), rank(right))
      return ranks.0 == ranks.1 ? left < right : ranks.0 < ranks.1
    }
    for key in ordered {
      let name = key.dropFirst("seven_day_".count).replacingOccurrences(of: "_", with: " ")
      let label = name.split(separator: " ").map { $0.capitalized }.joined(separator: " ")
      if let result = UsageParsing.window(root[key], label: label) { return result }
    }
    return nil
  }
}

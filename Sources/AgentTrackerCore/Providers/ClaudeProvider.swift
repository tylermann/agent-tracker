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
    let fileMaterial = ClaudeOAuthMaterial.parse(CredentialReading.json(at: file))
    // On macOS the live token lives in the keychain; Claude Code often leaves a leftover
    // ~/.claude/.credentials.json behind. Use the file only while its expiresAt is still in
    // the future so a stale file cannot mask a rotated keychain token. A file with no expiry
    // is treated as usable so tests (and older files) never fall through to the real keychain.
    if let fileMaterial, fileMaterial.isUnexpired() {
      return fileMaterial.asCredential
    }
    #if canImport(Security)
      for service in ["Claude Code-credentials", "claude-code-credentials"] {
        if let data = CredentialReading.keychainPassword(
          service: service, allowPrompt: allowKeychainPrompt, securityToolFallback: true),
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let keychain = ClaudeOAuthMaterial.parse(root)
        {
          return keychain.asCredential
        }
      }
    #endif
    if let fileMaterial { return fileMaterial.asCredential }
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

/// Claude Code OAuth payload shared by `~/.claude/.credentials.json` and the macOS keychain item.
struct ClaudeOAuthMaterial: Equatable, Sendable {
  var accessToken: String
  var expiresAt: Date?

  var asCredential: UsageCredential { UsageCredential(accessToken: accessToken) }

  func isUnexpired(now: Date = Date()) -> Bool {
    guard let expiresAt else { return true }
    return expiresAt > now
  }

  static func parse(_ root: [String: Any]?) -> ClaudeOAuthMaterial? {
    guard let oauth = root?["claudeAiOauth"] as? [String: Any],
      let token = CredentialReading.nonempty(oauth["accessToken"])
    else { return nil }
    return ClaudeOAuthMaterial(
      accessToken: token, expiresAt: expiryDate(oauth["expiresAt"] ?? oauth["expires_at"]))
  }

  /// `expiresAt` is an epoch, usually milliseconds. Unlike usage reset fields, a small number
  /// means 1970 (already expired), not a delta from now.
  static func expiryDate(_ value: Any?) -> Date? {
    if let number = UsageParsing.number(value) {
      if number > 10_000_000_000 { return Date(timeIntervalSince1970: number / 1_000) }
      return Date(timeIntervalSince1970: number)
    }
    guard let string = value as? String else { return nil }
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return fractional.date(from: string) ?? ISO8601DateFormatter().date(from: string)
  }
}

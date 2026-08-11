import CSQLite
import Foundation

enum CursorProvider {
  static let spec = ProviderSpec(
    harness: .cursor,
    resolutionExecutableName: "agent",
    wrapperFunctionNames: ["agent", "cursor-agent"],
    hooks: HookInstallation(
      configPath: ".cursor/hooks.json",
      events: [
        "sessionStart", "beforeSubmitPrompt", "preToolUse", "postToolUse", "postToolUseFailure",
        "beforeShellExecution", "afterShellExecution", "beforeMCPExecution", "afterMCPExecution",
        "afterFileEdit", "stop", "sessionEnd",
      ],
      style: .flatEntries,
      rootDefaults: ["version": 1],
      installReportLine: "Installed Cursor lifecycle hooks.",
      removeReportLine: "Removed Agent Tracker Cursor hooks."
    ),
    usage: UsageSpec(
      readCredential: readCredential(home:allowKeychainPrompt:),
      request: usageRequest(for:),
      parse: parseUsage(_:fetchedAt:)
    ),
    logoResourceName: "cursor"
  )

  static func parseUsage(_ data: Data, fetchedAt: Date) throws -> ProviderUsageSnapshot {
    let root = try UsageParsing.dictionary(data)
    guard let plan = (root["planUsage"] ?? root["plan_usage"]) as? [String: Any] else {
      throw UsageParseError.missingUsage
    }
    let limit = UsageParsing.number(plan["limit"])
    let included = UsageParsing.number(plan["includedSpend"] ?? plan["included_spend"])
    let remaining = UsageParsing.number(plan["remaining"])
    let reportedPercent = UsageParsing.number(
      plan["totalPercentUsed"] ?? plan["total_percent_used"])
    let derivedPercent: Double? = {
      guard let limit, limit > 0 else { return nil }
      if let included { return included / limit * 100 }
      if let remaining { return (limit - remaining) / limit * 100 }
      return nil
    }()
    guard let usedPercent = reportedPercent ?? derivedPercent else {
      throw UsageParseError.missingUsage
    }
    let namedPercent = UsageParsing.number(plan["apiPercentUsed"] ?? plan["api_percent_used"])
    let secondary = namedPercent.map { UsageWindow(label: "Named", usedPercent: $0) }

    var overage: UsageOverage?
    if let spend = (root["spendLimitUsage"] ?? root["spend_limit_usage"]) as? [String: Any] {
      let individualLimit = UsageParsing.number(
        spend["individualLimit"] ?? spend["individual_limit"])
      let pooledLimit = UsageParsing.number(spend["pooledLimit"] ?? spend["pooled_limit"])
      let overageLimit = individualLimit ?? pooledLimit
      let used =
        UsageParsing.number(spend["individualUsed"] ?? spend["individual_used"])
        ?? UsageParsing.number(spend["pooledUsed"] ?? spend["pooled_used"])
        ?? UsageParsing.number(spend["totalSpend"] ?? spend["total_spend"])
      let overagePercent: Double? = {
        guard let used, let overageLimit, overageLimit > 0 else { return nil }
        return used / overageLimit * 100
      }()
      overage = UsageOverage(
        isEnabled: UsageParsing.bool(root["enabled"]) ?? (overageLimit != nil),
        usedPercent: overagePercent,
        usedAmount: used.map { $0 / 100 },
        limitAmount: overageLimit.map { $0 / 100 },
        unit: "USD"
      )
    }
    return ProviderUsageSnapshot(
      harness: .cursor,
      primary: UsageWindow(
        label: "Included",
        usedPercent: usedPercent,
        resetsAt: UsageParsing.date(root["billingCycleEnd"] ?? root["billing_cycle_end"])
      ),
      secondary: secondary,
      overage: overage,
      fetchedAt: fetchedAt
    )
  }

  static func readCredential(home: URL, allowKeychainPrompt: Bool) throws -> UsageCredential {
    let database = home.appendingPathComponent(
      "Library/Application Support/Cursor/User/globalStorage/state.vscdb")
    if let token = stateToken(database: database, key: "cursorAuth/accessToken") {
      return UsageCredential(accessToken: token)
    }
    for path in [".cursor/auth.json", ".cursor-agent/auth.json", ".agent/auth.json"] {
      if let root = CredentialReading.json(at: home.appendingPathComponent(path)),
        let token = CredentialReading.nonempty(root["accessToken"])
      {
        return UsageCredential(accessToken: token)
      }
    }
    #if canImport(Security)
      for prefix in ["cursor-agent", "agent", "cursor"] {
        if let data = CredentialReading.keychainPassword(
          service: "\(prefix)-access-token", account: "\(prefix)-user",
          allowPrompt: allowKeychainPrompt),
          let token = String(data: data, encoding: .utf8), !token.isEmpty
        {
          return UsageCredential(accessToken: token)
        }
      }
    #endif
    throw CredentialReading.loggedOutError(allowKeychainPrompt: allowKeychainPrompt)
  }

  static func usageRequest(for credential: UsageCredential) -> URLRequest {
    var request = URLRequest(
      url: URL(
        string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage")!)
    request.httpMethod = "POST"
    request.httpBody = Data("{}".utf8)
    request.timeoutInterval = 15
    request.cachePolicy = .reloadIgnoringLocalCacheData
    request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
    return request
  }

  /// Reads a single value from Cursor's key/value state database (state.vscdb).
  private static func stateToken(database url: URL, key: String) -> String? {
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    guard
      let database = try? SQLiteDatabase(
        path: url.path, flags: SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX)
    else { return nil }
    guard
      let statement = try? database.prepare("SELECT value FROM ItemTable WHERE key = ? LIMIT 1")
    else { return nil }
    defer { sqlite3_finalize(statement) }
    database.bind([.text(key)], to: statement)
    guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0)
    else { return nil }
    let value = String(cString: text)
    return value.isEmpty ? nil : value
  }
}

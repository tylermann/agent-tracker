import CSQLite
import Foundation

#if canImport(Security)
  import LocalAuthentication
  import Security
#endif

public enum UsageAvailability: String, Codable, Equatable, Sendable {
  case ok
  case loggedOut
  case error
  case stale
}

public struct UsageWindow: Codable, Equatable, Sendable {
  public var label: String
  public var usedPercent: Double
  public var resetsAt: Date?

  public init(label: String, usedPercent: Double, resetsAt: Date? = nil) {
    self.label = label
    self.usedPercent = min(max(usedPercent, 0), 100)
    self.resetsAt = resetsAt
  }

  public var remainingPercent: Double { max(0, 100 - usedPercent) }
}

public struct UsageOverage: Codable, Equatable, Sendable {
  public var isEnabled: Bool
  public var usedPercent: Double?
  public var usedAmount: Double?
  public var limitAmount: Double?
  public var unit: String?

  public init(
    isEnabled: Bool,
    usedPercent: Double? = nil,
    usedAmount: Double? = nil,
    limitAmount: Double? = nil,
    unit: String? = nil
  ) {
    self.isEnabled = isEnabled
    self.usedPercent = usedPercent.map { min(max($0, 0), 100) }
    self.usedAmount = usedAmount
    self.limitAmount = limitAmount
    self.unit = unit
  }
}

public struct ProviderUsageSnapshot: Codable, Equatable, Sendable, Identifiable {
  public var id: Harness { harness }
  public var harness: Harness
  public var availability: UsageAvailability
  public var primary: UsageWindow?
  public var secondary: UsageWindow?
  public var modelSpecific: UsageWindow?
  public var overage: UsageOverage?
  public var message: String?
  public var fetchedAt: Date

  public init(
    harness: Harness,
    availability: UsageAvailability = .ok,
    primary: UsageWindow? = nil,
    secondary: UsageWindow? = nil,
    modelSpecific: UsageWindow? = nil,
    overage: UsageOverage? = nil,
    message: String? = nil,
    fetchedAt: Date = Date()
  ) {
    self.harness = harness
    self.availability = availability
    self.primary = primary
    self.secondary = secondary
    self.modelSpecific = modelSpecific
    self.overage = overage
    self.message = message
    self.fetchedAt = fetchedAt
  }
}

public enum UsageParseError: LocalizedError {
  case malformedResponse
  case missingUsage

  public var errorDescription: String? {
    switch self {
    case .malformedResponse: "The usage service returned malformed data."
    case .missingUsage: "The usage service did not return a supported usage bucket."
    }
  }
}

public enum UsageResponseParser {
  public static func claude(_ data: Data, fetchedAt: Date = Date()) throws
    -> ProviderUsageSnapshot
  {
    let root = try dictionary(data)
    guard let primary = window(root["five_hour"], label: "5h") else {
      throw UsageParseError.missingUsage
    }
    let secondary = window(root["seven_day"], label: "Week")
    let modelSpecific = claudeModelWindow(root)
    var overage: UsageOverage?
    if let value = root["extra_usage"] as? [String: Any] {
      overage = UsageOverage(
        isEnabled: bool(value["is_enabled"]) ?? false,
        usedPercent: number(value["utilization"]),
        usedAmount: number(value["used_credits"]),
        limitAmount: number(value["monthly_limit"]),
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

  public static func codex(_ data: Data, fetchedAt: Date = Date()) throws
    -> ProviderUsageSnapshot
  {
    let root = try dictionary(data)
    let limits = (root["rate_limit"] ?? root["rateLimits"]) as? [String: Any] ?? [:]
    let primary = codexWindow(
      limits["primary_window"] ?? limits["primary"],
      fallbackLabel: "Usage"
    )
    let secondary = codexWindow(
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

  public static func cursor(_ data: Data, fetchedAt: Date = Date()) throws
    -> ProviderUsageSnapshot
  {
    let root = try dictionary(data)
    guard let plan = (root["planUsage"] ?? root["plan_usage"]) as? [String: Any] else {
      throw UsageParseError.missingUsage
    }
    let limit = number(plan["limit"])
    let included = number(plan["includedSpend"] ?? plan["included_spend"])
    let remaining = number(plan["remaining"])
    let reportedPercent = number(plan["totalPercentUsed"] ?? plan["total_percent_used"])
    let derivedPercent: Double? = {
      guard let limit, limit > 0 else { return nil }
      if let included { return included / limit * 100 }
      if let remaining { return (limit - remaining) / limit * 100 }
      return nil
    }()
    guard let usedPercent = reportedPercent ?? derivedPercent else {
      throw UsageParseError.missingUsage
    }
    let namedPercent = number(plan["apiPercentUsed"] ?? plan["api_percent_used"])
    let secondary = namedPercent.map { UsageWindow(label: "Named", usedPercent: $0) }

    var overage: UsageOverage?
    if let spend = (root["spendLimitUsage"] ?? root["spend_limit_usage"]) as? [String: Any] {
      let individualLimit = number(spend["individualLimit"] ?? spend["individual_limit"])
      let pooledLimit = number(spend["pooledLimit"] ?? spend["pooled_limit"])
      let overageLimit = individualLimit ?? pooledLimit
      let used =
        number(spend["individualUsed"] ?? spend["individual_used"])
        ?? number(spend["pooledUsed"] ?? spend["pooled_used"])
        ?? number(spend["totalSpend"] ?? spend["total_spend"])
      let overagePercent: Double? = {
        guard let used, let overageLimit, overageLimit > 0 else { return nil }
        return used / overageLimit * 100
      }()
      overage = UsageOverage(
        isEnabled: bool(root["enabled"]) ?? (overageLimit != nil),
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
        resetsAt: date(root["billingCycleEnd"] ?? root["billing_cycle_end"])
      ),
      secondary: secondary,
      overage: overage,
      fetchedAt: fetchedAt
    )
  }

  private static func dictionary(_ data: Data) throws -> [String: Any] {
    guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw UsageParseError.malformedResponse
    }
    return root
  }

  private static func window(
    _ raw: Any?,
    label: String,
    usedKeys: [String] = ["utilization", "used_percentage", "usedPercent"]
  ) -> UsageWindow? {
    guard let value = raw as? [String: Any] else { return nil }
    guard let used = usedKeys.lazy.compactMap({ number(value[$0]) }).first else { return nil }
    let resetsAt = date(
      value["resets_at"] ?? value["reset_at"] ?? value["resetsAt"]
        ?? value["reset_after_seconds"]
    )
    return UsageWindow(label: label, usedPercent: used, resetsAt: resetsAt)
  }

  private static func codexWindow(_ raw: Any?, fallbackLabel: String) -> UsageWindow? {
    guard let value = raw as? [String: Any] else { return nil }
    let seconds =
      number(value["limit_window_seconds"] ?? value["window_seconds"])
      ?? number(value["limit_window_minutes"] ?? value["window_minutes"]).map { $0 * 60 }
    return window(
      value,
      label: seconds.map(codexWindowLabel) ?? fallbackLabel,
      usedKeys: ["used_percent", "usedPercent"]
    )
  }

  private static func codexWindowLabel(seconds: Double) -> String {
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

  private static func claudeModelWindow(_ root: [String: Any]) -> UsageWindow? {
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
      if let result = window(root[key], label: label) { return result }
    }
    return nil
  }

  private static func number(_ value: Any?) -> Double? {
    if let number = value as? NSNumber { return number.doubleValue }
    if let string = value as? String { return Double(string) }
    return nil
  }

  private static func bool(_ value: Any?) -> Bool? {
    if let value = value as? Bool { return value }
    if let value = value as? NSNumber { return value.boolValue }
    if let value = value as? String { return ["true", "1"].contains(value.lowercased()) }
    return nil
  }

  private static func date(_ value: Any?) -> Date? {
    if let number = number(value) {
      // Epoch values from these services may be seconds, milliseconds, or a reset delta.
      if number > 10_000_000_000 { return Date(timeIntervalSince1970: number / 1_000) }
      if number > 1_000_000_000 { return Date(timeIntervalSince1970: number) }
      return Date().addingTimeInterval(number)
    }
    guard let string = value as? String else { return nil }
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return fractional.date(from: string) ?? ISO8601DateFormatter().date(from: string)
  }
}

public struct UsageCredential: Equatable, Sendable {
  public var accessToken: String
  public var accountID: String?

  public init(accessToken: String, accountID: String? = nil) {
    self.accessToken = accessToken
    self.accountID = accountID
  }
}

public enum UsageCredentialError: LocalizedError {
  case loggedOut
  case unavailable(String)

  public var errorDescription: String? {
    switch self {
    case .loggedOut: "Not logged in"
    case .unavailable(let message): message
    }
  }
}

public enum UsageCredentialReader {
  public static func claude(
    home: URL = FileManager.default.homeDirectoryForCurrentUser,
    allowKeychainPrompt: Bool = true
  ) throws
    -> UsageCredential
  {
    let file = home.appendingPathComponent(".claude/.credentials.json")
    if let root = json(at: file),
      let oauth = root["claudeAiOauth"] as? [String: Any],
      let token = nonempty(oauth["accessToken"])
    {
      return UsageCredential(accessToken: token)
    }
    #if canImport(Security)
      for service in ["Claude Code-credentials", "claude-code-credentials"] {
        if let data = keychainPassword(service: service, allowPrompt: allowKeychainPrompt),
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let oauth = root["claudeAiOauth"] as? [String: Any],
          let token = nonempty(oauth["accessToken"])
        {
          return UsageCredential(accessToken: token)
        }
      }
    #endif
    if !allowKeychainPrompt {
      throw UsageCredentialError.unavailable("Click refresh to authorize")
    }
    throw UsageCredentialError.loggedOut
  }

  public static func codex(
    home: URL = FileManager.default.homeDirectoryForCurrentUser,
    allowKeychainPrompt: Bool = true
  ) throws
    -> UsageCredential
  {
    let file = home.appendingPathComponent(".codex/auth.json")
    if let root = json(at: file), let credential = codexCredential(root) { return credential }
    #if canImport(Security)
      // Codex uses this service when cli_auth_credentials_store is `keyring` or `auto`.
      if let data = keychainPassword(
        service: "Codex Auth", allowPrompt: allowKeychainPrompt),
        let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let credential = codexCredential(root)
      {
        return credential
      }
    #endif
    if !allowKeychainPrompt {
      throw UsageCredentialError.unavailable("Click refresh to authorize")
    }
    throw UsageCredentialError.loggedOut
  }

  public static func cursor(
    home: URL = FileManager.default.homeDirectoryForCurrentUser,
    allowKeychainPrompt: Bool = true
  ) throws
    -> UsageCredential
  {
    let database = home.appendingPathComponent(
      "Library/Application Support/Cursor/User/globalStorage/state.vscdb")
    if let token = sqliteValue(database: database, key: "cursorAuth/accessToken") {
      return UsageCredential(accessToken: token)
    }
    for path in [".cursor/auth.json", ".cursor-agent/auth.json", ".agent/auth.json"] {
      if let root = json(at: home.appendingPathComponent(path)),
        let token = nonempty(root["accessToken"])
      {
        return UsageCredential(accessToken: token)
      }
    }
    #if canImport(Security)
      for prefix in ["cursor-agent", "agent", "cursor"] {
        if let data = keychainPassword(
          service: "\(prefix)-access-token", account: "\(prefix)-user",
          allowPrompt: allowKeychainPrompt),
          let token = String(data: data, encoding: .utf8), !token.isEmpty
        {
          return UsageCredential(accessToken: token)
        }
      }
    #endif
    if !allowKeychainPrompt {
      throw UsageCredentialError.unavailable("Click refresh to authorize")
    }
    throw UsageCredentialError.loggedOut
  }

  private static func json(at url: URL) -> [String: Any]? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
  }

  private static func nonempty(_ value: Any?) -> String? {
    guard let value = value as? String, !value.isEmpty else { return nil }
    return value
  }

  private static func codexCredential(_ root: [String: Any]) -> UsageCredential? {
    guard let tokens = root["tokens"] as? [String: Any],
      let token = nonempty(tokens["access_token"])
    else { return nil }
    return UsageCredential(accessToken: token, accountID: nonempty(tokens["account_id"]))
  }

  private static func sqliteValue(database url: URL, key: String) -> String? {
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    var database: OpaquePointer?
    let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
    guard sqlite3_open_v2(url.path, &database, flags, nil) == SQLITE_OK, let database else {
      sqlite3_close(database)
      return nil
    }
    defer { sqlite3_close(database) }
    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(
        database, "SELECT value FROM ItemTable WHERE key = ? LIMIT 1", -1, &statement, nil)
        == SQLITE_OK,
      let statement
    else { return nil }
    defer { sqlite3_finalize(statement) }
    sqlite3_bind_text(statement, 1, key, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else {
      return nil
    }
    let value = String(cString: text)
    return value.isEmpty ? nil : value
  }

  #if canImport(Security)
    private static func keychainPassword(
      service: String,
      account: String? = nil,
      allowPrompt: Bool = true
    ) -> Data? {
      var query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecReturnData as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne,
      ]
      if let account { query[kSecAttrAccount as String] = account }
      if !allowPrompt {
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
      }
      var result: CFTypeRef?
      guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
      return result as? Data
    }
  #endif
}

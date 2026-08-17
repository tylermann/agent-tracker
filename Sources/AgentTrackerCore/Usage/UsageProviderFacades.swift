import Foundation

/// Stable harness-keyed entry points into the per-provider usage implementations. The bodies live
/// in Providers/<Name>Provider.swift; prefer `ProviderRegistry.spec(for:).usage` when iterating
/// providers generically.
public enum UsageResponseParser {
  public static func claude(_ data: Data, fetchedAt: Date = Date()) throws
    -> ProviderUsageSnapshot
  {
    try ClaudeProvider.parseUsage(data, fetchedAt: fetchedAt)
  }

  public static func codex(_ data: Data, fetchedAt: Date = Date()) throws
    -> ProviderUsageSnapshot
  {
    try CodexProvider.parseUsage(data, fetchedAt: fetchedAt)
  }

  public static func cursor(_ data: Data, fetchedAt: Date = Date()) throws
    -> ProviderUsageSnapshot
  {
    try CursorProvider.parseUsage(data, fetchedAt: fetchedAt)
  }

  public static func cursorUsageEvents(_ data: Data) throws
    -> (events: [CursorUsageEvent], totalCount: Int)
  {
    try CursorProvider.parseUsageEvents(data)
  }
}

/// Request builders needed outside the generic `UsageSpec` flow.
public enum UsageRequestBuilder {
  public static func cursorUsageEvents(
    credential: UsageCredential, startMs: Int64, endMs: Int64, page: Int, pageSize: Int = 200
  ) -> URLRequest {
    CursorProvider.usageEventsRequest(
      for: credential, startMs: startMs, endMs: endMs, page: page, pageSize: pageSize)
  }
}

public enum UsageCredentialReader {
  public static func claude(
    home: URL = FileManager.default.homeDirectoryForCurrentUser,
    allowKeychainPrompt: Bool = true
  ) throws -> UsageCredential {
    try ClaudeProvider.readCredential(home: home, allowKeychainPrompt: allowKeychainPrompt)
  }

  public static func codex(
    home: URL = FileManager.default.homeDirectoryForCurrentUser,
    allowKeychainPrompt: Bool = true
  ) throws -> UsageCredential {
    try CodexProvider.readCredential(home: home, allowKeychainPrompt: allowKeychainPrompt)
  }

  public static func cursor(
    home: URL = FileManager.default.homeDirectoryForCurrentUser,
    allowKeychainPrompt: Bool = true
  ) throws -> UsageCredential {
    try CursorProvider.readCredential(home: home, allowKeychainPrompt: allowKeychainPrompt)
  }
}

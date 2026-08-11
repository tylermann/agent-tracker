import Foundation

#if canImport(Security)
  import LocalAuthentication
  import Security
#endif

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

/// File and keychain helpers shared by the provider credential readers.
enum CredentialReading {
  static func json(at url: URL) -> [String: Any]? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
  }

  static func nonempty(_ value: Any?) -> String? {
    guard let value = value as? String, !value.isEmpty else { return nil }
    return value
  }

  /// The error a reader throws once every credential source has come up empty. When keychain
  /// prompts were suppressed, the caller is told to refresh (which retries with prompts allowed)
  /// rather than being reported as logged out.
  static func loggedOutError(allowKeychainPrompt: Bool) -> UsageCredentialError {
    allowKeychainPrompt ? .loggedOut : .unavailable("Click refresh to authorize")
  }

  #if canImport(Security)
    static func keychainPassword(
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

import Foundation

#if canImport(Security)
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
    /// Serializes keychain reads so a prompt-allowed lookup on one provider cannot re-enable
    /// dialogs while another provider's silent lookup is in flight (interaction allowance is
    /// process-global).
    private static let keychainLock = NSLock()

    static func keychainPassword(
      service: String,
      account: String? = nil,
      allowPrompt: Bool = true,
      securityToolFallback: Bool = false
    ) -> Data? {
      keychainLock.lock()
      defer { keychainLock.unlock() }
      if let data = item(service: service, account: account, interactive: false) { return data }
      // Claude Code resets its item's keychain partition list to `apple-tool:` every time it
      // refreshes the OAuth token, revoking this app's "Always Allow" grant several times a day
      // no matter how the app is signed. /usr/bin/security matches that partition and holds a
      // durable Apple-signed ACL entry on the item, so reading through it survives every
      // rotation. It runs even when prompts are suppressed: at worst macOS asks once ever (to
      // authorize the security tool) instead of once per rotation.
      if securityToolFallback {
        return securityToolPassword(service: service, account: account)
      }
      guard allowPrompt else { return nil }
      return item(service: service, account: account, interactive: true)
    }

    /// `SecKeychainSetUserInteractionAllowed` is deprecated without a replacement, but it is the
    /// only call that actually suppresses login-keychain ACL dialogs; LocalAuthentication's
    /// `interactionNotAllowed` governs the data-protection keychain and leaves them enabled.
    private static func item(service: String, account: String?, interactive: Bool) -> Data? {
      SecKeychainSetUserInteractionAllowed(interactive)
      defer { SecKeychainSetUserInteractionAllowed(false) }
      var query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecReturnData as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne,
      ]
      if let account { query[kSecAttrAccount as String] = account }
      var result: CFTypeRef?
      guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
      return result as? Data
    }

    private static func securityToolPassword(service: String, account: String?) -> Data? {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
      var arguments = ["find-generic-password", "-s", service]
      if let account { arguments += ["-a", account] }
      arguments.append("-w")
      process.arguments = arguments
      let output = Pipe()
      process.standardOutput = output
      process.standardError = FileHandle.nullDevice
      do { try process.run() } catch { return nil }
      let data = output.fileHandleForReading.readDataToEndOfFile()
      process.waitUntilExit()
      guard process.terminationStatus == 0 else { return nil }
      var password = data
      if password.last == UInt8(ascii: "\n") { password.removeLast() }
      return password.isEmpty ? nil : password
    }
  #endif
}

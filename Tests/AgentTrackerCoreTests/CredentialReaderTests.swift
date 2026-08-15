import XCTest

@testable import AgentTrackerCore

/// File-based credential paths only. Every test must return from a credential file BEFORE the
/// reader falls through to its keychain lookup: the lookup targets the real login keychain by
/// service name, so it would read the developer's actual credentials, and the Claude reader's
/// /usr/bin/security fallback can show an ACL password prompt even with
/// `allowKeychainPrompt: false`.
final class CredentialReaderTests: XCTestCase {
  private var home: URL!

  override func setUpWithError() throws {
    home = FileManager.default.temporaryDirectory
      .appendingPathComponent("AgentTrackerCredentials-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: home)
  }

  func testReadsClaudeCredentialFile() throws {
    try write(
      #"{"claudeAiOauth":{"accessToken":"claude-token"}}"#, to: ".claude/.credentials.json")
    let credential = try UsageCredentialReader.claude(home: home, allowKeychainPrompt: false)
    XCTAssertEqual(credential.accessToken, "claude-token")
    XCTAssertNil(credential.accountID)
  }

  func testReadsCodexCredentialFileWithAccountID() throws {
    try write(
      #"{"tokens":{"access_token":"codex-token","account_id":"acct-1"}}"#, to: ".codex/auth.json")
    let credential = try UsageCredentialReader.codex(home: home, allowKeychainPrompt: false)
    XCTAssertEqual(credential.accessToken, "codex-token")
    XCTAssertEqual(credential.accountID, "acct-1")
  }

  func testReadsCursorCredentialFromAuthFile() throws {
    try write(#"{"accessToken":"cursor-token"}"#, to: ".cursor/auth.json")
    let credential = try UsageCredentialReader.cursor(home: home, allowKeychainPrompt: false)
    XCTAssertEqual(credential.accessToken, "cursor-token")
  }

  private func write(_ contents: String, to relativePath: String) throws {
    let url = home.appendingPathComponent(relativePath)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(contents.utf8).write(to: url)
  }
}

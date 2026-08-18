import XCTest

@testable import AgentTrackerCore

final class ClaudeCredentialSelectionTests: XCTestCase {
  func testParseReadsAccessTokenAndMillisecondExpiry() {
    let material = ClaudeOAuthMaterial.parse([
      "claudeAiOauth": [
        "accessToken": "file-token",
        "expiresAt": 1_700_000_000_000,
      ]
    ])

    XCTAssertEqual(material?.accessToken, "file-token")
    XCTAssertEqual(material?.expiresAt, Date(timeIntervalSince1970: 1_700_000_000))
  }

  func testParseReadsSnakeCaseExpiryAndSecondEpoch() {
    let material = ClaudeOAuthMaterial.parse([
      "claudeAiOauth": [
        "accessToken": "file-token",
        "expires_at": 1_700_000_000,
      ]
    ])

    XCTAssertEqual(material?.expiresAt, Date(timeIntervalSince1970: 1_700_000_000))
  }

  func testSmallExpiryNumberIsEpochNotDeltaFromNow() {
    let material = ClaudeOAuthMaterial.parse([
      "claudeAiOauth": [
        "accessToken": "expired-token",
        "expiresAt": 1,
      ]
    ])

    XCTAssertEqual(material?.expiresAt, Date(timeIntervalSince1970: 1))
    XCTAssertFalse(material?.isUnexpired(now: Date(timeIntervalSince1970: 100)) ?? true)
  }

  func testMissingExpiryIsTreatedAsUsable() {
    let material = ClaudeOAuthMaterial.parse([
      "claudeAiOauth": ["accessToken": "legacy-token"]
    ])

    XCTAssertNil(material?.expiresAt)
    XCTAssertEqual(material?.isUnexpired(), true)
  }

  func testExpiredMaterialIsNotUsable() {
    let material = ClaudeOAuthMaterial(
      accessToken: "old", expiresAt: Date(timeIntervalSince1970: 1_700_000_000))
    XCTAssertFalse(material.isUnexpired(now: Date(timeIntervalSince1970: 1_700_000_001)))
    XCTAssertTrue(material.isUnexpired(now: Date(timeIntervalSince1970: 1_699_999_999)))
  }

  func testParseRejectsMissingAccessToken() {
    XCTAssertNil(
      ClaudeOAuthMaterial.parse([
        "claudeAiOauth": ["expiresAt": 1_700_000_000_000]
      ]))
  }
}

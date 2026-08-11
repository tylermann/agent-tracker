import XCTest

@testable import AgentTrackerCore

final class UsageTests: XCTestCase {
  func testParsesClaudeWindowsModelBucketAndOverage() throws {
    let data = Data(
      #"""
      {
        "five_hour":{"utilization":37,"resets_at":"2026-08-10T20:00:00.000Z"},
        "seven_day":{"utilization":26,"resets_at":"2026-08-14T20:00:00Z"},
        "seven_day_fable":{"utilization":11,"resets_at":"2026-08-15T20:00:00Z"},
        "extra_usage":{"is_enabled":true,"monthly_limit":50,"used_credits":4,"utilization":8}
      }
      """#.utf8)

    let snapshot = try UsageResponseParser.claude(data)

    XCTAssertEqual(snapshot.harness, .claude)
    XCTAssertEqual(snapshot.primary?.label, "5h")
    XCTAssertEqual(snapshot.primary?.usedPercent, 37)
    XCTAssertEqual(snapshot.secondary?.usedPercent, 26)
    XCTAssertEqual(snapshot.modelSpecific?.label, "Fable")
    XCTAssertEqual(snapshot.modelSpecific?.usedPercent, 11)
    XCTAssertEqual(snapshot.overage?.isEnabled, true)
    XCTAssertEqual(snapshot.overage?.usedPercent, 8)
  }

  func testParsesCodexPrimaryAndWeeklyWindows() throws {
    let data = Data(
      #"""
      {
        "plan_type":"pro",
        "rate_limit":{
          "primary_window":{"used_percent":72,"limit_window_seconds":18000,"reset_at":1786399200},
          "secondary_window":{"used_percent":41,"limit_window_seconds":604800,"reset_at":1786827600}
        }
      }
      """#.utf8)

    let snapshot = try UsageResponseParser.codex(data)

    XCTAssertEqual(snapshot.harness, .codex)
    XCTAssertEqual(snapshot.primary?.label, "5h")
    XCTAssertEqual(snapshot.primary?.remainingPercent, 28)
    XCTAssertEqual(snapshot.secondary?.label, "Week")
    XCTAssertEqual(snapshot.secondary?.usedPercent, 41)
    XCTAssertNotNil(snapshot.primary?.resetsAt)
  }

  func testLabelsCodexWeeklyOnlyWindowFromDuration() throws {
    let data = Data(
      #"""
      {
        "rate_limit":{
          "primary_window":{"used_percent":59,"limit_window_seconds":604800}
        }
      }
      """#.utf8)

    let snapshot = try UsageResponseParser.codex(data)

    XCTAssertEqual(snapshot.primary?.label, "Week")
    XCTAssertEqual(snapshot.primary?.remainingPercent, 41)
    XCTAssertNil(snapshot.secondary)
  }

  func testParsesCursorIncludedPoolNamedShareAndOverage() throws {
    let data = Data(
      #"""
      {
        "billingCycleEnd":"1788912000000",
        "planUsage":{
          "includedSpend":7500,
          "remaining":2500,
          "limit":10000,
          "totalPercentUsed":75,
          "apiPercentUsed":62
        },
        "spendLimitUsage":{
          "totalSpend":200,
          "individualLimit":2000,
          "individualUsed":200
        },
        "enabled":true
      }
      """#.utf8)

    let snapshot = try UsageResponseParser.cursor(data)

    XCTAssertEqual(snapshot.harness, .cursor)
    XCTAssertEqual(snapshot.primary?.label, "Included")
    XCTAssertEqual(snapshot.primary?.remainingPercent, 25)
    XCTAssertEqual(snapshot.secondary?.label, "Named")
    XCTAssertEqual(snapshot.secondary?.usedPercent, 62)
    XCTAssertEqual(snapshot.overage?.usedPercent, 10)
    XCTAssertEqual(snapshot.overage?.usedAmount, 2)
    XCTAssertEqual(snapshot.overage?.limitAmount, 20)
    XCTAssertNotNil(snapshot.primary?.resetsAt)
  }

  func testCursorDerivesPercentWhenServerOmitsIt() throws {
    let data = Data(#"{"planUsage":{"includedSpend":30,"limit":200}}"#.utf8)

    let snapshot = try UsageResponseParser.cursor(data)

    XCTAssertEqual(snapshot.primary?.usedPercent, 15)
  }

  func testRejectsUnsupportedPayload() {
    XCTAssertThrowsError(try UsageResponseParser.codex(Data(#"{"ok":true}"#.utf8)))
  }
}

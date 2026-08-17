import XCTest

@testable import AgentTrackerCore

final class CursorUsageEventsTests: XCTestCase {
  func testParsesCamelCaseEvents() throws {
    let payload = """
      {
        "totalUsageEventsCount": 2,
        "usageEventsDisplay": [
          {
            "timestamp": "1786838400000",
            "model": "grok-4.6",
            "tokenUsage": {
              "inputTokens": 100, "outputTokens": 20,
              "cacheReadTokens": 500, "cacheWriteTokens": 10
            }
          },
          {
            "timestamp": "1786924800000",
            "model": "composer-2",
            "tokenUsage": {"inputTokens": 3, "outputTokens": 4}
          }
        ]
      }
      """
    let parsed = try UsageResponseParser.cursorUsageEvents(Data(payload.utf8))

    XCTAssertEqual(parsed.totalCount, 2)
    XCTAssertEqual(parsed.events.count, 2)
    XCTAssertEqual(parsed.events[0].model, "grok-4.6")
    XCTAssertEqual(
      parsed.events[0].counters,
      TokenUsageCounters(input: 100, output: 20, cacheRead: 500, cacheWrite: 10))
    XCTAssertEqual(
      parsed.events[0].timestamp, Date(timeIntervalSince1970: 1_786_838_400))
  }

  func testParsesSnakeCaseEvents() throws {
    let payload = """
      {
        "total_usage_events_count": 1,
        "usage_events": [
          {
            "created_at": 1786838400000,
            "model_intent": "grok-4.6",
            "token_usage": {"input_tokens": 7, "output_tokens": 8}
          }
        ]
      }
      """
    let parsed = try UsageResponseParser.cursorUsageEvents(Data(payload.utf8))
    XCTAssertEqual(parsed.totalCount, 1)
    XCTAssertEqual(parsed.events.first?.model, "grok-4.6")
    XCTAssertEqual(parsed.events.first?.counters, TokenUsageCounters(input: 7, output: 8))
  }

  func testEventWithoutTokenUsageIsKeptWhenItNamesAModel() throws {
    let payload = """
      {
        "usageEvents": [
          {"timestamp": "1786838400000", "model": "grok-4.6"},
          {"timestamp": "1786838400000"}
        ]
      }
      """
    let parsed = try UsageResponseParser.cursorUsageEvents(Data(payload.utf8))
    XCTAssertEqual(parsed.events.count, 1)
    XCTAssertEqual(parsed.events.first?.counters, TokenUsageCounters())
  }

  func testMissingUsageEventsKeyThrows() {
    XCTAssertThrowsError(
      try UsageResponseParser.cursorUsageEvents(Data(#"{"unexpected": true}"#.utf8))
    ) { error in
      XCTAssertTrue(error is UsageParseError)
    }
  }

  func testDailyRowsBucketByLocalDayAndModel() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    let midnight = Date(timeIntervalSince1970: 1_786_838_400)  // 2026-08-16T00:00:00Z
    let events = [
      CursorUsageEvent(
        timestamp: midnight, model: "grok-4.6", counters: TokenUsageCounters(input: 1)),
      CursorUsageEvent(
        timestamp: midnight.addingTimeInterval(3_600), model: "GROK_4.6",
        counters: TokenUsageCounters(input: 2)),
      CursorUsageEvent(
        timestamp: midnight.addingTimeInterval(-60), model: "grok-4.6",
        counters: TokenUsageCounters(input: 4)),
    ]

    let rows = CursorUsageEvent.dailyRows(from: events, calendar: calendar)
      .sorted { $0.day < $1.day }
    XCTAssertEqual(rows.count, 2)
    XCTAssertEqual(rows[0].day, "2026-08-15")
    XCTAssertEqual(rows[0].counters, TokenUsageCounters(input: 4))
    XCTAssertEqual(rows[1].day, "2026-08-16")
    XCTAssertEqual(rows[1].model, "grok-4.6")
    XCTAssertEqual(rows[1].counters, TokenUsageCounters(input: 3))
    XCTAssertTrue(rows.allSatisfy { $0.harness == .cursor })
  }

  func testUsageEventsRequestShape() throws {
    let request = UsageRequestBuilder.cursorUsageEvents(
      credential: UsageCredential(accessToken: "token"),
      startMs: 1_786_838_400_000, endMs: 1_786_924_800_000, page: 2, pageSize: 200)

    XCTAssertEqual(
      request.url?.absoluteString,
      "https://api2.cursor.sh/aiserver.v1.DashboardService/GetFilteredUsageEvents")
    XCTAssertEqual(request.httpMethod, "POST")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Connect-Protocol-Version"), "1")
    let body =
      try JSONSerialization.jsonObject(
        with: XCTUnwrap(request.httpBody)) as? [String: Any]
    XCTAssertEqual(body?["startDate"] as? String, "1786838400000")
    XCTAssertEqual(body?["endDate"] as? String, "1786924800000")
    XCTAssertEqual(body?["page"] as? Int, 2)
    XCTAssertEqual(body?["pageSize"] as? Int, 200)
    XCTAssertEqual(body?["teamId"] as? Int, 0)
  }
}

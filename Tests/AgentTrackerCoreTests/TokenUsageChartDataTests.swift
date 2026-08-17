import XCTest

@testable import AgentTrackerCore

final class TokenUsageChartDataTests: XCTestCase {
  private var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    calendar.firstWeekday = 2
    return calendar
  }

  private var now: Date {
    calendar.date(from: DateComponents(year: 2026, month: 8, day: 16, hour: 12))!
  }

  private func row(
    day: String, harness: Harness = .claude, model: String = "claude-fable-5",
    input: Int = 0, output: Int = 0, cacheRead: Int = 0
  ) -> TokenUsageRow {
    TokenUsageRow(
      day: day, harness: harness, model: model,
      counters: TokenUsageCounters(input: input, output: output, cacheRead: cacheRead))
  }

  func testDayModeBucketsTheLastFourteenDaysZeroFilled() {
    let data = TokenUsageChartData.build(
      rows: [row(day: "2026-08-14", input: 5, output: 5)],
      granularity: .day, calendar: calendar, now: now)

    XCTAssertEqual(data.buckets.count, TokenUsageChartData.dayBucketCount)
    XCTAssertEqual(data.buckets.first?.key, "2026-08-03")
    XCTAssertEqual(data.buckets.last?.key, "2026-08-16")
    XCTAssertEqual(data.series.count, 1)
    let values = data.series[0].values
    XCTAssertEqual(values.count, TokenUsageChartData.dayBucketCount)
    XCTAssertEqual(values[11], 10)
    XCTAssertEqual(values.reduce(0, +), 10)
  }

  func testWeekModeBucketsByLocalWeekStart() {
    // 2026-08-16 is a Sunday; with Monday weeks it belongs to the week starting 2026-08-10.
    let data = TokenUsageChartData.build(
      rows: [
        row(day: "2026-08-16", input: 3),
        row(day: "2026-08-10", input: 4),
        row(day: "2026-08-09", input: 5),
      ],
      granularity: .week, calendar: calendar, now: now)

    XCTAssertEqual(data.buckets.count, TokenUsageChartData.weekBucketCount)
    XCTAssertEqual(data.buckets.last?.key, "2026-08-10")
    let values = data.series[0].values
    XCTAssertEqual(values.last, 7)
    XCTAssertEqual(values[values.count - 2], 5)
  }

  func testRowsOutsideTheRangeAreDropped() {
    let data = TokenUsageChartData.build(
      rows: [row(day: "2026-01-01", input: 100)],
      granularity: .day, calendar: calendar, now: now)
    XCTAssertTrue(data.isEmpty)
  }

  func testFreshTokensExcludeCacheReads() {
    let data = TokenUsageChartData.build(
      rows: [row(day: "2026-08-16", input: 10, output: 5, cacheRead: 100_000)],
      granularity: .day, calendar: calendar, now: now)
    XCTAssertEqual(data.series[0].total, 15)
  }

  func testSeriesAreProviderMajorThenRankedByTotal() {
    let data = TokenUsageChartData.build(
      rows: [
        row(day: "2026-08-16", harness: .codex, model: "gpt-5.6-sol", input: 50),
        row(day: "2026-08-16", harness: .claude, model: "claude-opus-5", input: 1),
        row(day: "2026-08-16", harness: .claude, model: "claude-fable-5", input: 9),
      ],
      granularity: .day, calendar: calendar, now: now)

    XCTAssertEqual(data.series.map(\.model), ["claude-fable-5", "claude-opus-5", "gpt-5.6-sol"])
    XCTAssertEqual(data.series.map(\.shadeIndex), [0, 1, 0])
  }

  func testOverflowModelsFoldIntoOther() {
    let rows = (1...6).map { index in
      row(day: "2026-08-16", model: "model-\(index)", input: 100 - index)
    }
    let data = TokenUsageChartData.build(
      rows: rows, granularity: .day, calendar: calendar, now: now)

    XCTAssertEqual(data.series.count, TokenUsageChartData.seriesPerHarness)
    XCTAssertEqual(data.series.map(\.model), ["model-1", "model-2", "model-3", "other"])
    XCTAssertEqual(data.series.last?.total, 96 + 95 + 94)
    XCTAssertEqual(data.series.last?.shadeIndex, TokenUsageChartData.seriesPerHarness - 1)
  }

  func testExactlyFourModelsNeedNoOtherFold() {
    let rows = (1...4).map { index in
      row(day: "2026-08-16", model: "model-\(index)", input: index)
    }
    let data = TokenUsageChartData.build(
      rows: rows, granularity: .day, calendar: calendar, now: now)
    XCTAssertEqual(data.series.count, 4)
    XCTAssertFalse(data.series.contains { $0.model == TokenUsageChartData.otherModelKey })
  }

  func testShadeIndicesAreStableAcrossGranularities() {
    let rows = [
      row(day: "2026-08-16", model: "claude-fable-5", input: 9),
      row(day: "2026-08-16", model: "claude-opus-5", input: 1),
    ]
    let day = TokenUsageChartData.build(
      rows: rows, granularity: .day, calendar: calendar, now: now)
    let week = TokenUsageChartData.build(
      rows: rows, granularity: .week, calendar: calendar, now: now)
    XCTAssertEqual(
      day.series.map { "\($0.model):\($0.shadeIndex)" },
      week.series.map { "\($0.model):\($0.shadeIndex)" })
  }
}

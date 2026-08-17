import Foundation

public enum TokenUsageGranularity: String, CaseIterable, Sendable {
  case day
  case week
}

/// Prepares `token_usage_daily` rows for the sidebar chart: a fixed bucket range (zero-filled so
/// quiet stretches render as gaps) and a bounded series list with stable shade assignments, so
/// colors do not jump when the granularity toggles.
public struct TokenUsageChartData: Equatable, Sendable {
  public static let dayBucketCount = 14
  public static let weekBucketCount = 12
  static let seriesPerHarness = 4

  public struct Bucket: Equatable, Sendable {
    public var key: String
    public var label: String
    public var start: Date
  }

  public struct Series: Equatable, Sendable, Identifiable {
    public var id: String { "\(harness.rawValue)|\(model)" }
    public var harness: Harness
    /// Normalized model key; empty when unknown, "other" for the per-harness overflow fold.
    public var model: String
    /// Rank within the harness by total, 0 = largest. Drives the color shade.
    public var shadeIndex: Int
    /// Fresh tokens per bucket, aligned with `buckets`.
    public var values: [Int]
    public var total: Int
  }

  public static let otherModelKey = "other"

  public var buckets: [Bucket]
  public var series: [Series]

  public var isEmpty: Bool { series.isEmpty }
  public var totalFreshTokens: Int { series.reduce(0) { $0 + $1.total } }

  public static func build(
    rows: [TokenUsageRow],
    granularity: TokenUsageGranularity,
    calendar: Calendar = .current,
    now: Date = Date()
  ) -> TokenUsageChartData {
    let buckets = makeBuckets(granularity: granularity, calendar: calendar, now: now)
    let indexByKey = Dictionary(
      uniqueKeysWithValues: buckets.enumerated().map { ($0.element.key, $0.offset) })

    struct SeriesKey: Hashable {
      var harness: Harness
      var model: String
    }
    var values: [SeriesKey: [Int]] = [:]
    for row in rows {
      guard let date = date(fromDay: row.day, calendar: calendar) else { continue }
      let bucketKey =
        switch granularity {
        case .day: row.day
        case .week: weekKey(for: date, calendar: calendar)
        }
      guard let index = indexByKey[bucketKey] else { continue }
      let key = SeriesKey(harness: row.harness, model: row.model)
      values[key, default: Array(repeating: 0, count: buckets.count)][index] +=
        row.counters.fresh
    }

    struct RankedSeries {
      var model: String
      var values: [Int]
      var total: Int
    }
    var series: [Series] = []
    for harness in Harness.allCases {
      var ranked: [RankedSeries] = []
      for (key, seriesValues) in values where key.harness == harness {
        let total = seriesValues.reduce(0, +)
        if total > 0 {
          ranked.append(RankedSeries(model: key.model, values: seriesValues, total: total))
        }
      }
      ranked.sort { lhs, rhs in
        lhs.total != rhs.total ? lhs.total > rhs.total : lhs.model < rhs.model
      }
      let kept = ranked.prefix(
        ranked.count > seriesPerHarness ? seriesPerHarness - 1 : seriesPerHarness)
      for (index, entry) in kept.enumerated() {
        series.append(
          Series(
            harness: harness, model: entry.model, shadeIndex: index,
            values: entry.values, total: entry.total))
      }
      let overflow = ranked.dropFirst(kept.count)
      if !overflow.isEmpty {
        var folded = Array(repeating: 0, count: buckets.count)
        for entry in overflow {
          for (index, value) in entry.values.enumerated() { folded[index] += value }
        }
        series.append(
          Series(
            harness: harness, model: otherModelKey, shadeIndex: seriesPerHarness - 1,
            values: folded, total: folded.reduce(0, +)))
      }
    }
    return TokenUsageChartData(buckets: buckets, series: series)
  }

  private static func makeBuckets(
    granularity: TokenUsageGranularity, calendar: Calendar, now: Date
  ) -> [Bucket] {
    let formatter = DateFormatter()
    formatter.calendar = calendar
    formatter.timeZone = calendar.timeZone
    formatter.setLocalizedDateFormatFromTemplate("Md")

    switch granularity {
    case .day:
      let today = calendar.startOfDay(for: now)
      return (0..<dayBucketCount).reversed().compactMap { offset in
        guard let start = calendar.date(byAdding: .day, value: -offset, to: today) else {
          return nil
        }
        return Bucket(
          key: TokenUsageDayKey.day(for: start, calendar: calendar),
          label: formatter.string(from: start),
          start: start)
      }
    case .week:
      let thisWeek =
        calendar.dateInterval(of: .weekOfYear, for: now)?.start
        ?? calendar.startOfDay(for: now)
      return (0..<weekBucketCount).reversed().compactMap { offset in
        guard let start = calendar.date(byAdding: .weekOfYear, value: -offset, to: thisWeek)
        else { return nil }
        return Bucket(
          key: TokenUsageDayKey.day(for: start, calendar: calendar),
          label: formatter.string(from: start),
          start: start)
      }
    }
  }

  private static func weekKey(for date: Date, calendar: Calendar) -> String {
    let start = calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? date
    return TokenUsageDayKey.day(for: start, calendar: calendar)
  }

  private static func date(fromDay day: String, calendar: Calendar) -> Date? {
    let parts = day.split(separator: "-").compactMap { Int($0) }
    guard parts.count == 3 else { return nil }
    var components = DateComponents()
    components.year = parts[0]
    components.month = parts[1]
    components.day = parts[2]
    return calendar.date(from: components)
  }
}

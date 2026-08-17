import Foundation

/// One per-request usage event from Cursor's dashboard service. Cursor writes no token counts to
/// local files, so the token history chart gets its Cursor data from these events instead.
public struct CursorUsageEvent: Equatable, Sendable {
  public var timestamp: Date
  public var model: String?
  public var counters: TokenUsageCounters

  public init(timestamp: Date, model: String?, counters: TokenUsageCounters) {
    self.timestamp = timestamp
    self.model = model
    self.counters = counters
  }

  /// Buckets events into per-day rows for `token_usage_daily`.
  public static func dailyRows(
    from events: [CursorUsageEvent], calendar: Calendar = .current
  ) -> [TokenUsageRow] {
    struct BucketKey: Hashable {
      var day: String
      var model: String
    }
    var buckets: [BucketKey: TokenUsageCounters] = [:]
    for event in events {
      let key = BucketKey(
        day: TokenUsageDayKey.day(for: event.timestamp, calendar: calendar),
        model: TokenUsageModelKey.normalized(event.model)
      )
      buckets[key, default: TokenUsageCounters()] += event.counters
    }
    return buckets.map { key, counters in
      TokenUsageRow(day: key.day, harness: .cursor, model: key.model, counters: counters)
    }
  }
}

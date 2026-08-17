import Foundation

/// Absolute token counts for one aggregation bucket.
public struct TokenUsageCounters: Equatable, Sendable {
  public var input: Int
  public var output: Int
  public var cacheRead: Int
  public var cacheWrite: Int

  public init(input: Int = 0, output: Int = 0, cacheRead: Int = 0, cacheWrite: Int = 0) {
    self.input = input
    self.output = output
    self.cacheRead = cacheRead
    self.cacheWrite = cacheWrite
  }

  /// Tokens processed fresh — what the history chart plots. Cache reads are excluded: they
  /// dominate raw totals (routinely 20x the rest combined) while representing replayed prompt
  /// rather than new work.
  public var fresh: Int { input + cacheWrite + output }

  public var isEmpty: Bool { input == 0 && output == 0 && cacheRead == 0 && cacheWrite == 0 }

  public static func + (lhs: Self, rhs: Self) -> Self {
    Self(
      input: lhs.input + rhs.input,
      output: lhs.output + rhs.output,
      cacheRead: lhs.cacheRead + rhs.cacheRead,
      cacheWrite: lhs.cacheWrite + rhs.cacheWrite
    )
  }

  public static func += (lhs: inout Self, rhs: Self) {
    lhs = lhs + rhs
  }
}

/// One row of the `token_usage_daily` table.
public struct TokenUsageRow: Equatable, Sendable {
  public var day: String
  public var harness: Harness
  public var model: String
  public var counters: TokenUsageCounters

  public init(day: String, harness: Harness, model: String, counters: TokenUsageCounters) {
    self.day = day
    self.harness = harness
    self.model = model
    self.counters = counters
  }
}

/// Resume position for one scanned transcript, or the Cursor sync row (`cursorEventsPath`), where
/// `model` holds the last synced day instead of a model.
public struct TokenUsageScanState: Equatable, Sendable {
  public static let cursorEventsPath = "cursor://events"

  public var path: String
  public var byteOffset: Int
  public var fileSize: Int
  public var modifiedAt: Double
  /// Codex names the serving model on a `turn_context` record that usually precedes the resume
  /// offset, so the model active at `byteOffset` is carried here between scans.
  public var model: String?

  public init(
    path: String, byteOffset: Int, fileSize: Int, modifiedAt: Double, model: String? = nil
  ) {
    self.path = path
    self.byteOffset = byteOffset
    self.fileSize = fileSize
    self.modifiedAt = modifiedAt
    self.model = model
  }
}

/// Day bucketing for token aggregation: local-timezone "YYYY-MM-DD" strings, which sort
/// chronologically and survive DST because the calendar owns the day boundaries.
public enum TokenUsageDayKey {
  public static func day(for date: Date, calendar: Calendar = .current) -> String {
    let parts = calendar.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
  }
}

/// Aggregation key for a raw provider model string: lightly canonicalized so the same model
/// reported through different channels lands in one bucket, empty when unknown so the UI can fall
/// back to the harness name.
public enum TokenUsageModelKey {
  public static func normalized(_ raw: String?) -> String {
    guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
      return ""
    }
    if let bracket = value.firstIndex(of: "[") {
      value = String(value[..<bracket]).trimmingCharacters(in: .whitespaces)
    }
    return value.lowercased().replacingOccurrences(of: "_", with: "-")
  }
}

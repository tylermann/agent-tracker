import Foundation

/// JSON coercion helpers shared by the provider usage parsers.
enum UsageParsing {
  static func dictionary(_ data: Data) throws -> [String: Any] {
    guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw UsageParseError.malformedResponse
    }
    return root
  }

  static func window(
    _ raw: Any?,
    label: String,
    usedKeys: [String] = ["utilization", "used_percentage", "usedPercent"]
  ) -> UsageWindow? {
    guard let value = raw as? [String: Any] else { return nil }
    guard let used = usedKeys.lazy.compactMap({ number(value[$0]) }).first else { return nil }
    let resetsAt = date(
      value["resets_at"] ?? value["reset_at"] ?? value["resetsAt"]
        ?? value["reset_after_seconds"]
    )
    return UsageWindow(label: label, usedPercent: used, resetsAt: resetsAt)
  }

  static func number(_ value: Any?) -> Double? {
    if let number = value as? NSNumber { return number.doubleValue }
    if let string = value as? String { return Double(string) }
    return nil
  }

  static func bool(_ value: Any?) -> Bool? {
    if let value = value as? Bool { return value }
    if let value = value as? NSNumber { return value.boolValue }
    if let value = value as? String { return ["true", "1"].contains(value.lowercased()) }
    return nil
  }

  static func date(_ value: Any?) -> Date? {
    if let number = number(value) {
      // Epoch values from these services may be seconds, milliseconds, or a reset delta.
      if number > 10_000_000_000 { return Date(timeIntervalSince1970: number / 1_000) }
      if number > 1_000_000_000 { return Date(timeIntervalSince1970: number) }
      return Date().addingTimeInterval(number)
    }
    guard let string = value as? String else { return nil }
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return fractional.date(from: string) ?? ISO8601DateFormatter().date(from: string)
  }
}

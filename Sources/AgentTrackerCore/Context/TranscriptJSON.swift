import Foundation

/// Line-level decoding shared by the transcript readers (context occupancy and token usage).
enum TranscriptJSON {
  static func object(from line: Data) -> [String: Any]? {
    guard !line.isEmpty else { return nil }
    return try? JSONSerialization.jsonObject(with: line) as? [String: Any]
  }

  static func integer(_ value: Any?) -> Int {
    if let int = value as? Int { return int }
    if let double = value as? Double { return Int(double) }
    return 0
  }
}

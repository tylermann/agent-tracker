import Foundation

/// How full a session's context window was as of the last model turn recorded in its transcript.
///
/// Claude and Codex are derived from the transcript each harness writes to disk. Cursor supplies
/// the same two numbers through a local status-line callback. Transcript and callback payload
/// content is discarded; only these totals are retained.
public struct SessionContext: Codable, Equatable, Sendable {
  public var usedTokens: Int
  public var windowTokens: Int
  /// The model that produced the sampled turn, when the transcript names one. Kept for the
  /// tooltip; the window size is already resolved.
  public var model: String?

  public init(usedTokens: Int, windowTokens: Int, model: String? = nil) {
    self.usedTokens = max(0, usedTokens)
    self.windowTokens = max(0, windowTokens)
    self.model = model
  }

  /// Clamped to 1: a turn can momentarily price out above the window (the harness compacts right
  /// after), and a bar that overflows its track reads as a rendering bug.
  public var fraction: Double {
    guard windowTokens > 0 else { return 0 }
    return min(max(Double(usedTokens) / Double(windowTokens), 0), 1)
  }

  public var usedPercent: Double { fraction * 100 }
}

/// Context window sizes per model, for the harnesses whose transcripts record a model name but not
/// the window it was served with. Codex reports its own window and never consults this.
public enum ModelContextWindow {
  /// Matched in order against the lowercased model ID, so the pinned legacy IDs win over the
  /// family-wide fallbacks below them. An unrecognized model returns nil and the row shows no bar,
  /// which is the honest outcome — a guessed denominator would silently misreport how full a
  /// session is.
  private static let table: [(needle: String, tokens: Int)] = [
    ("haiku", 200_000),
    ("opus-4-5", 200_000),
    ("opus-4-1", 200_000),
    ("opus-4-0", 200_000),
    ("opus-3", 200_000),
    ("sonnet-4-5", 200_000),
    ("sonnet-4-0", 200_000),
    ("sonnet-3", 200_000),
    ("fable", 1_000_000),
    ("mythos", 1_000_000),
    ("opus", 1_000_000),
    ("sonnet", 1_000_000),
  ]

  public static func tokens(for model: String) -> Int? {
    let normalized = model.lowercased()
    return table.first { normalized.contains($0.needle) }?.tokens
  }
}

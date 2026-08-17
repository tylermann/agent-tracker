import Foundation

/// Extracts the current context occupancy from a harness transcript.
///
/// Both formats are JSON Lines that only ever get appended to, and both restate the whole context
/// size on every model turn — so the answer is always the last matching line, and compaction needs
/// no special handling: the turn after a compaction simply reports a smaller prompt.
enum TranscriptContextParser {
  static func parse(harness: Harness, lines: [Data]) -> SessionContext? {
    switch harness {
    case .claude: claude(lines: lines)
    case .codex: codex(lines: lines)
    case .cursor: nil
    }
  }

  /// Claude records per-message `usage`, so occupancy is the whole prompt it just sent (fresh
  /// input, cache writes, and cache reads) plus the reply that will be part of the next prompt.
  ///
  /// Sidechain lines are subagent turns against their own context windows, and `<synthetic>`
  /// messages are locally generated rather than served — neither describes the session's own
  /// window, so both are skipped.
  private static func claude(lines: [Data]) -> SessionContext? {
    for line in lines.reversed() {
      guard let record = object(from: line),
        record["type"] as? String == "assistant",
        record["isSidechain"] as? Bool != true,
        let message = record["message"] as? [String: Any],
        let usage = message["usage"] as? [String: Any]
      else { continue }
      let model = message["model"] as? String
      guard let model, model != "<synthetic>", let window = ModelContextWindow.tokens(for: model)
      else { continue }

      let used =
        integer(usage["input_tokens"]) + integer(usage["cache_creation_input_tokens"])
        + integer(usage["cache_read_input_tokens"]) + integer(usage["output_tokens"])
      guard used > 0 else { continue }
      return SessionContext(usedTokens: used, windowTokens: window, model: model)
    }
    return nil
  }

  /// Codex emits a `token_count` event carrying both halves of the answer, including the window
  /// for the model actually serving the session — so no model lookup table is involved. Its model
  /// is recorded separately on `turn_context`, so both latest values are collected before return.
  private static func codex(lines: [Data]) -> SessionContext? {
    var occupancy: (used: Int, window: Int)?
    var model: String?
    for line in lines.reversed() {
      guard let record = object(from: line),
        let payload = record["payload"] as? [String: Any]
      else { continue }

      if model == nil, record["type"] as? String == "turn_context" {
        model = payload["model"] as? String
      }
      if occupancy == nil, payload["type"] as? String == "token_count",
        let info = payload["info"] as? [String: Any],
        let window = info["model_context_window"] as? Int,
        window > 0,
        let last = info["last_token_usage"] as? [String: Any]
      {
        let used = integer(last["total_tokens"])
        if used > 0 { occupancy = (used, window) }
      }
      if let occupancy, let model {
        return SessionContext(
          usedTokens: occupancy.used, windowTokens: occupancy.window, model: model)
      }
    }
    guard let occupancy else { return nil }
    return SessionContext(
      usedTokens: occupancy.used, windowTokens: occupancy.window, model: model)
  }

  private static func object(from line: Data) -> [String: Any]? {
    TranscriptJSON.object(from: line)
  }

  private static func integer(_ value: Any?) -> Int {
    TranscriptJSON.integer(value)
  }
}

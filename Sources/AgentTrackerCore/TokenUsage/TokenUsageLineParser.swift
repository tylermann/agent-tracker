import Foundation

/// Extracts per-request token usage from harness transcript lines for daily aggregation.
///
/// Unlike `TranscriptContextParser`, which wants only the latest context occupancy, these parsers
/// walk forward and emit one sample per API request so the samples can be summed.
enum TokenUsageLineParser {
  struct Sample {
    var date: Date
    var model: String?
    var counters: TokenUsageCounters
  }

  enum CodexLine {
    case model(String)
    case sample(Sample)
  }

  /// Claude transcripts carry one `usage` block per assistant message, and each message is one
  /// API request, so the sum over messages is the billed usage. Sidechain (subagent) messages are
  /// real spend and are included — the context parser skips them because they describe a different
  /// window, but that distinction does not apply to totals. `<synthetic>` messages are locally
  /// generated, never served, and carry no real usage.
  static func claude(line: Data) -> Sample? {
    guard let record = TranscriptJSON.object(from: line),
      record["type"] as? String == "assistant",
      let message = record["message"] as? [String: Any],
      let usage = message["usage"] as? [String: Any]
    else { return nil }
    let model = message["model"] as? String
    guard model != "<synthetic>", let date = timestamp(record["timestamp"]) else { return nil }
    let counters = TokenUsageCounters(
      input: TranscriptJSON.integer(usage["input_tokens"]),
      output: TranscriptJSON.integer(usage["output_tokens"]),
      cacheRead: TranscriptJSON.integer(usage["cache_read_input_tokens"]),
      cacheWrite: TranscriptJSON.integer(usage["cache_creation_input_tokens"])
    )
    guard !counters.isEmpty else { return nil }
    return Sample(date: date, model: model, counters: counters)
  }

  /// Codex `token_count` events carry per-turn usage in `last_token_usage`, whose `input_tokens`
  /// includes the cached prefix — subtracted here so `input` is fresh input only. Reasoning tokens
  /// are already part of `output_tokens` and are never added separately. The serving model arrives
  /// on separate `turn_context` records, surfaced as `.model` for the caller to carry forward.
  static func codex(line: Data) -> CodexLine? {
    guard let record = TranscriptJSON.object(from: line),
      let payload = record["payload"] as? [String: Any]
    else { return nil }
    if record["type"] as? String == "turn_context", let model = payload["model"] as? String {
      return .model(model)
    }
    guard payload["type"] as? String == "token_count",
      let info = payload["info"] as? [String: Any],
      let last = info["last_token_usage"] as? [String: Any],
      let date = timestamp(record["timestamp"])
    else { return nil }
    let inputIncludingCache = TranscriptJSON.integer(last["input_tokens"])
    let cacheRead = TranscriptJSON.integer(last["cached_input_tokens"])
    let counters = TokenUsageCounters(
      input: max(0, inputIncludingCache - cacheRead),
      output: TranscriptJSON.integer(last["output_tokens"]),
      cacheRead: cacheRead,
      cacheWrite: TranscriptJSON.integer(last["cache_write_input_tokens"])
    )
    guard !counters.isEmpty else { return nil }
    return .sample(Sample(date: date, model: nil, counters: counters))
  }

  private static func timestamp(_ value: Any?) -> Date? {
    guard let string = value as? String else { return nil }
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return fractional.date(from: string) ?? ISO8601DateFormatter().date(from: string)
  }
}

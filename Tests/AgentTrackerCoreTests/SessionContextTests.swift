import XCTest

@testable import AgentTrackerCore

final class SessionContextTests: XCTestCase {
  private func lines(_ raw: String) -> [Data] {
    raw.split(separator: "\n").map { Data($0.utf8) }
  }

  func testClaudeUsesTheLastMainThreadTurn() throws {
    let context = TranscriptContextParser.parse(
      harness: .claude,
      lines: lines(
        """
        {"type":"assistant","message":{"model":"claude-opus-5","usage":{"input_tokens":2,"cache_creation_input_tokens":100,"cache_read_input_tokens":900,"output_tokens":50}}}
        {"type":"user","message":{"role":"user","content":"hello"}}
        {"type":"assistant","message":{"model":"claude-opus-5","usage":{"input_tokens":2,"cache_creation_input_tokens":2414,"cache_read_input_tokens":35099,"output_tokens":471}}}
        """))

    XCTAssertEqual(context?.usedTokens, 37_986)
    XCTAssertEqual(context?.windowTokens, 1_000_000)
    XCTAssertEqual(context?.model, "claude-opus-5")
  }

  /// Subagent turns run against their own windows and synthetic messages were never served, so a
  /// trailing run of either must not be mistaken for the session's own occupancy.
  func testClaudeSkipsSidechainAndSyntheticTurns() throws {
    let context = TranscriptContextParser.parse(
      harness: .claude,
      lines: lines(
        """
        {"type":"assistant","message":{"model":"claude-opus-5","usage":{"input_tokens":10,"cache_read_input_tokens":40000,"output_tokens":100}}}
        {"type":"assistant","isSidechain":true,"message":{"model":"claude-opus-5","usage":{"input_tokens":5,"cache_read_input_tokens":300,"output_tokens":20}}}
        {"type":"assistant","message":{"model":"<synthetic>","usage":{"input_tokens":1,"output_tokens":1}}}
        """))

    XCTAssertEqual(context?.usedTokens, 40_110)
  }

  func testClaudeIgnoresTurnsFromUnknownModels() throws {
    let context = TranscriptContextParser.parse(
      harness: .claude,
      lines: lines(
        """
        {"type":"assistant","message":{"model":"some-other-vendor-model","usage":{"input_tokens":10,"output_tokens":5}}}
        """))

    XCTAssertNil(context)
  }

  /// A partial first line is expected — the sampler reads a byte window, not whole records.
  func testClaudeToleratesATruncatedLeadingLine() throws {
    let context = TranscriptContextParser.parse(
      harness: .claude,
      lines: lines(
        """
        _tokens":900,"output_tokens":50}}}
        {"type":"assistant","message":{"model":"claude-haiku-4-5","usage":{"input_tokens":1000,"output_tokens":24}}}
        """))

    XCTAssertEqual(context?.usedTokens, 1_024)
    XCTAssertEqual(context?.windowTokens, 200_000)
  }

  /// Codex states its own window, so no model lookup is involved.
  func testCodexReadsBothHalvesFromTheTokenCountEvent() throws {
    let context = TranscriptContextParser.parse(
      harness: .codex,
      lines: lines(
        """
        {"type":"turn_context","payload":{"model":"gpt-5.6-sol"}}
        {"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":1000},"model_context_window":258400}}}
        {"type":"response_item","payload":{"type":"message"}}
        {"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":42713},"model_context_window":258400}}}
        """))

    XCTAssertEqual(context?.usedTokens, 42_713)
    XCTAssertEqual(context?.windowTokens, 258_400)
    XCTAssertEqual(context?.model, "gpt-5.6-sol")
  }

  func testCodexSkipsTokenCountEventsWithoutUsage() throws {
    let context = TranscriptContextParser.parse(
      harness: .codex,
      lines: lines(
        """
        {"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":900},"model_context_window":258400}}}
        {"type":"event_msg","payload":{"type":"token_count","info":null}}
        """))

    XCTAssertEqual(context?.usedTokens, 900)
  }

  func testCursorHasNoContextSource() throws {
    XCTAssertNil(TranscriptContextParser.parse(harness: .cursor, lines: lines("{}")))
  }

  func testContextWindowLookupPrefersPinnedLegacyIdentifiers() throws {
    XCTAssertEqual(ModelContextWindow.tokens(for: "claude-opus-5"), 1_000_000)
    XCTAssertEqual(ModelContextWindow.tokens(for: "claude-fable-5"), 1_000_000)
    XCTAssertEqual(ModelContextWindow.tokens(for: "claude-sonnet-5"), 1_000_000)
    XCTAssertEqual(ModelContextWindow.tokens(for: "claude-haiku-4-5"), 200_000)
    XCTAssertEqual(ModelContextWindow.tokens(for: "claude-opus-4-5-20251101"), 200_000)
    XCTAssertEqual(ModelContextWindow.tokens(for: "claude-sonnet-4-5-20250929"), 200_000)
    XCTAssertNil(ModelContextWindow.tokens(for: "gpt-5"))
  }

  func testFractionClampsWhenATurnPricesOutAboveTheWindow() throws {
    let context = SessionContext(usedTokens: 250_000, windowTokens: 200_000)
    XCTAssertEqual(context.fraction, 1)
    XCTAssertEqual(SessionContext(usedTokens: 100, windowTokens: 0).fraction, 0)
  }
}

final class ContextSamplerTests: XCTestCase {
  private var home: URL!

  override func setUpWithError() throws {
    home = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("agent-tracker-context-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: home)
  }

  private func writeClaudeTranscript(sessionID: String, cacheRead: Int) throws -> URL {
    let directory = home.appendingPathComponent(
      ".claude/projects/-Users-someone-project", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("\(sessionID).jsonl")
    let line = """
      {"type":"assistant","message":{"model":"claude-opus-5","usage":{"input_tokens":2,\
      "cache_read_input_tokens":\(cacheRead),"output_tokens":10}}}

      """
    try Data(line.utf8).write(to: url)
    return url
  }

  private func run(sessionID: String) -> TrackedRun {
    TrackedRun(runID: "run-1", harness: .claude, harnessSessionID: sessionID)
  }

  func testLocatesAClaudeTranscriptBySessionIDAndTracksAppends() throws {
    let sessionID = UUID().uuidString
    let url = try writeClaudeTranscript(sessionID: sessionID, cacheRead: 1_000)
    let sampler = ContextSampler(home: home)

    XCTAssertEqual(sampler.sample(run(sessionID: sessionID))?.usedTokens, 1_012)

    let appended = """
      {"type":"assistant","message":{"model":"claude-opus-5","usage":{"input_tokens":2,\
      "cache_read_input_tokens":5000,"output_tokens":10}}}

      """
    let handle = try FileHandle(forWritingTo: url)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(appended.utf8))
    try handle.close()

    XCTAssertEqual(sampler.sample(run(sessionID: sessionID))?.usedTokens, 5_012)
  }

  func testReturnsNilWhenNoTranscriptExists() throws {
    let sampler = ContextSampler(home: home)
    XCTAssertNil(sampler.sample(run(sessionID: UUID().uuidString)))
  }

  func testRunsWithoutASessionIDAreSkipped() throws {
    let sampler = ContextSampler(home: home)
    let run = TrackedRun(runID: "run-2", harness: .claude, harnessSessionID: nil)
    XCTAssertNil(sampler.sample(run))
  }

  /// A missing transcript must not be re-searched on every tick, so the second lookup inside the
  /// interval stays cold even once the file appears.
  func testTranscriptLookupIsThrottledAfterAMiss() throws {
    let sessionID = UUID().uuidString
    let sampler = ContextSampler(home: home)
    let start = Date()
    XCTAssertNil(sampler.sample(run(sessionID: sessionID), now: start))

    _ = try writeClaudeTranscript(sessionID: sessionID, cacheRead: 2_000)
    XCTAssertNil(sampler.sample(run(sessionID: sessionID), now: start.addingTimeInterval(1)))
    XCTAssertEqual(
      sampler.sample(run(sessionID: sessionID), now: start.addingTimeInterval(30))?.usedTokens,
      2_012)
  }

  func testRetainDropsCachedRunsThatLeftTheList() throws {
    let sessionID = UUID().uuidString
    _ = try writeClaudeTranscript(sessionID: sessionID, cacheRead: 3_000)
    let sampler = ContextSampler(home: home)
    XCTAssertNotNil(sampler.sample(run(sessionID: sessionID)))

    sampler.retain(runIDs: [])
    // The entry is gone, so the next sample starts from an unlocated transcript again.
    XCTAssertNil(sampler.sample(run(sessionID: sessionID), now: .distantPast))
  }
}

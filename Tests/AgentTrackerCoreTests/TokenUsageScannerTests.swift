import XCTest

@testable import AgentTrackerCore

final class TokenUsageScannerTests: XCTestCase {
  private var home: URL!
  private var scanner: TokenUsageScanner!

  override func setUpWithError() throws {
    home = FileManager.default.temporaryDirectory
      .appendingPathComponent("AgentTrackerScannerTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    // Canonicalize /var -> /private/var so fixture paths match the scanner's enumerated paths.
    home = URL(
      fileURLWithPath: try XCTUnwrap(
        home.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath))
    scanner = TokenUsageScanner(home: home, calendar: utcCalendar)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: home)
  }

  private var utcCalendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
  }

  private func claudeLine(
    day: String, model: String = "claude-fable-5", input: Int, output: Int,
    cacheRead: Int = 0, cacheWrite: Int = 0, sidechain: Bool = false
  ) -> String {
    """
    {"type":"assistant","isSidechain":\(sidechain),"timestamp":"\(day)T10:00:00.000Z",\
    "message":{"model":"\(model)","usage":{"input_tokens":\(input),\
    "cache_creation_input_tokens":\(cacheWrite),"cache_read_input_tokens":\(cacheRead),\
    "output_tokens":\(output)}}}
    """
  }

  private func codexTurnContext(model: String) -> String {
    #"{"timestamp":"2026-08-15T09:00:00.000Z","type":"turn_context","payload":{"model":"\#(model)"}}"#
  }

  private func codexTokenCount(day: String, input: Int, cached: Int, output: Int) -> String {
    """
    {"timestamp":"\(day)T11:00:00.000Z","type":"event_msg","payload":{"type":"token_count",\
    "info":{"last_token_usage":{"input_tokens":\(input),"cached_input_tokens":\(cached),\
    "cache_write_input_tokens":0,"output_tokens":\(output),"reasoning_output_tokens":1,\
    "total_tokens":\(input + output)}}}}
    """
  }

  @discardableResult
  private func write(_ lines: [String], to relativePath: String, trailingNewline: Bool = true)
    throws -> URL
  {
    let url = home.appendingPathComponent(relativePath)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let content = lines.joined(separator: "\n") + (trailingNewline ? "\n" : "")
    try content.write(to: url, atomically: true, encoding: .utf8)
    return url
  }

  private func append(_ lines: [String], to url: URL) throws {
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: Data((lines.joined(separator: "\n") + "\n").utf8))
  }

  private func states(from result: TokenUsageScanner.ScanResult) -> [String: TokenUsageScanState] {
    Dictionary(uniqueKeysWithValues: result.states.map { ($0.path, $0) })
  }

  func testBackfillAggregatesPerDayAndModel() throws {
    try write(
      [
        claudeLine(day: "2026-08-14", input: 100, output: 20, cacheRead: 500, cacheWrite: 10),
        claudeLine(day: "2026-08-14", input: 50, output: 5),
        claudeLine(day: "2026-08-15", model: "claude-opus-5", input: 7, output: 3),
      ],
      to: ".claude/projects/slug/session-a.jsonl")
    try write(
      [
        codexTurnContext(model: "gpt-5.6-sol"),
        codexTokenCount(day: "2026-08-15", input: 500, cached: 400, output: 30),
      ],
      to: ".codex/sessions/2026/08/15/rollout-2026-08-15T11-00-00-b.jsonl")

    let result = scanner.scan(states: [:])

    XCTAssertEqual(result.deltas.count, 3)
    let claude14 = result.deltas.first { $0.day == "2026-08-14" }
    XCTAssertEqual(claude14?.harness, .claude)
    XCTAssertEqual(claude14?.model, "claude-fable-5")
    XCTAssertEqual(
      claude14?.counters,
      TokenUsageCounters(input: 150, output: 25, cacheRead: 500, cacheWrite: 10))
    let codex15 = result.deltas.first { $0.harness == .codex }
    XCTAssertEqual(codex15?.day, "2026-08-15")
    XCTAssertEqual(codex15?.model, "gpt-5.6-sol")
    XCTAssertEqual(codex15?.counters, TokenUsageCounters(input: 100, output: 30, cacheRead: 400))
    XCTAssertEqual(result.states.count, 2)
    XCTAssertTrue(result.removedPaths.isEmpty)
  }

  func testIncrementalScanCountsOnlyNewBytes() throws {
    let url = try write(
      [claudeLine(day: "2026-08-14", input: 100, output: 20)],
      to: ".claude/projects/slug/session-a.jsonl")
    let first = scanner.scan(states: [:])

    try append([claudeLine(day: "2026-08-15", input: 9, output: 1)], to: url)
    let second = scanner.scan(states: states(from: first))

    XCTAssertEqual(second.deltas.count, 1)
    XCTAssertEqual(second.deltas.first?.day, "2026-08-15")
    XCTAssertEqual(second.deltas.first?.counters, TokenUsageCounters(input: 9, output: 1))
  }

  func testUnchangedFileIsSkippedWithoutNewState() throws {
    try write(
      [claudeLine(day: "2026-08-14", input: 100, output: 20)],
      to: ".claude/projects/slug/session-a.jsonl")
    let first = scanner.scan(states: [:])
    let second = scanner.scan(states: states(from: first))
    XCTAssertTrue(second.deltas.isEmpty)
    XCTAssertTrue(second.states.isEmpty)
  }

  func testTornTrailingLineIsDeferredThenCountedOnce() throws {
    let complete = claudeLine(day: "2026-08-14", input: 100, output: 20)
    let torn = claudeLine(day: "2026-08-15", input: 9, output: 1)
    let cut = torn.index(torn.startIndex, offsetBy: torn.count / 2)
    let url = try write(
      [complete + "\n" + String(torn[..<cut])],
      to: ".claude/projects/slug/session-a.jsonl",
      trailingNewline: false)

    let first = scanner.scan(states: [:])
    XCTAssertEqual(first.deltas.count, 1)
    XCTAssertEqual(first.deltas.first?.day, "2026-08-14")

    let handle = try FileHandle(forWritingTo: url)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data((String(torn[cut...]) + "\n").utf8))
    try handle.close()

    let second = scanner.scan(states: states(from: first))
    XCTAssertEqual(second.deltas.count, 1)
    XCTAssertEqual(second.deltas.first?.day, "2026-08-15")
    XCTAssertEqual(second.deltas.first?.counters, TokenUsageCounters(input: 9, output: 1))
  }

  func testShrunkFileResetsWithoutDoubleCounting() throws {
    let url = try write(
      [claudeLine(day: "2026-08-14", input: 100, output: 20)],
      to: ".claude/projects/slug/session-a.jsonl")
    let size = try XCTUnwrap(
      (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue)
    let previous = TokenUsageScanState(
      path: url.path, byteOffset: size + 500, fileSize: size + 500, modifiedAt: 1)

    let result = scanner.scan(states: [url.path: previous])
    XCTAssertTrue(result.deltas.isEmpty)
    XCTAssertEqual(result.states.first?.byteOffset, size)
  }

  func testCodexModelCarriesAcrossScans() throws {
    let url = try write(
      [
        codexTurnContext(model: "gpt-5.6-sol"),
        codexTokenCount(day: "2026-08-15", input: 500, cached: 400, output: 30),
      ],
      to: ".codex/sessions/2026/08/15/rollout-2026-08-15T11-00-00-b.jsonl")
    let first = scanner.scan(states: [:])
    XCTAssertEqual(first.states.first?.model, "gpt-5.6-sol")

    try append([codexTokenCount(day: "2026-08-16", input: 50, cached: 40, output: 3)], to: url)
    let second = scanner.scan(states: states(from: first))
    XCTAssertEqual(second.deltas.count, 1)
    XCTAssertEqual(second.deltas.first?.model, "gpt-5.6-sol")
    XCTAssertEqual(
      second.deltas.first?.counters, TokenUsageCounters(input: 10, output: 3, cacheRead: 40))
  }

  func testClaudeSidechainIncludedAndSyntheticSkipped() throws {
    try write(
      [
        claudeLine(day: "2026-08-14", input: 100, output: 20, sidechain: true),
        claudeLine(day: "2026-08-14", model: "<synthetic>", input: 999, output: 999),
      ],
      to: ".claude/projects/slug/session-a.jsonl")

    let result = scanner.scan(states: [:])
    XCTAssertEqual(result.deltas.count, 1)
    XCTAssertEqual(result.deltas.first?.counters, TokenUsageCounters(input: 100, output: 20))
  }

  func testMalformedLinesAreSkipped() throws {
    try write(
      [
        "not json at all",
        #"{"type":"assistant"}"#,
        claudeLine(day: "2026-08-14", input: 1, output: 2),
      ],
      to: ".claude/projects/slug/session-a.jsonl")

    let result = scanner.scan(states: [:])
    XCTAssertEqual(result.deltas.count, 1)
    XCTAssertEqual(result.deltas.first?.counters, TokenUsageCounters(input: 1, output: 2))
  }

  func testDeletedFileIsReportedForStateRemoval() throws {
    let gone = TokenUsageScanState(
      path: home.appendingPathComponent(".claude/projects/slug/gone.jsonl").path,
      byteOffset: 10, fileSize: 10, modifiedAt: 1)
    let cursor = TokenUsageScanState(
      path: TokenUsageScanState.cursorEventsPath, byteOffset: 0, fileSize: 0, modifiedAt: 1)

    let result = scanner.scan(states: [gone.path: gone, cursor.path: cursor])
    XCTAssertEqual(result.removedPaths, [gone.path])
  }

  func testDayBucketingUsesTheCalendarTimezone() throws {
    var pacific = Calendar(identifier: .gregorian)
    pacific.timeZone = TimeZone(identifier: "Etc/GMT+8")!
    scanner = TokenUsageScanner(home: home, calendar: pacific)
    // 07:30 UTC is 23:30 the previous day at UTC-8.
    try write(
      [
        """
        {"type":"assistant","timestamp":"2026-08-16T07:30:00.000Z","message":\
        {"model":"claude-fable-5","usage":{"input_tokens":1,"output_tokens":1}}}
        """
      ],
      to: ".claude/projects/slug/session-a.jsonl")

    let result = scanner.scan(states: [:])
    XCTAssertEqual(result.deltas.first?.day, "2026-08-15")
  }
}

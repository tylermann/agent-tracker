import XCTest

@testable import AgentTrackerCore

final class CursorContextTests: XCTestCase {
  func testParsesAuthoritativeStatusLinePercentage() throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let payload = Data(
      #"""
      {
        "session_id":"cursor-session",
        "model":{"id":"gpt-5.6-sol","display_name":"GPT-5.6 Sol"},
        "context_window":{
          "total_input_tokens":999,
          "context_window_size":272000,
          "used_percentage":34.5,
          "remaining_percentage":65.5
        }
      }
      """#.utf8)

    let snapshot = try XCTUnwrap(
      CursorContextPayloadParser.statusLine(
        payload,
        environment: ["AGENT_TRACKER_RUN_ID": "wrapped-run"],
        now: now
      ))

    XCTAssertEqual(snapshot.runID, "wrapped-run")
    XCTAssertEqual(snapshot.sessionID, "cursor-session")
    XCTAssertEqual(snapshot.context.usedTokens, 93_840)
    XCTAssertEqual(snapshot.context.windowTokens, 272_000)
    XCTAssertEqual(snapshot.context.model, "gpt-5.6-sol")
    XCTAssertEqual(snapshot.source, .statusLine)
    XCTAssertEqual(snapshot.updatedAt, now)
  }

  func testStatusLineUsesOrphanIdentityAndInputFallback() throws {
    let payload = Data(
      #"{"session_id":"cursor-session","context_window":{"total_input_tokens":12000,"context_window_size":200000}}"#
        .utf8)
    let snapshot = try XCTUnwrap(
      CursorContextPayloadParser.statusLine(payload, environment: [:]))
    XCTAssertEqual(snapshot.runID, "orphan-cursor-session")
    XCTAssertEqual(snapshot.context.usedTokens, 12_000)
  }

  func testParsesStopHookTokenBreakdownAndContextParameter() throws {
    let payload = Data(
      #"""
      {
        "conversation_id":"cursor-session",
        "model":"claude-opus-5[context=1m,effort=high]",
        "model_params":[{"id":"context","value":"1m"}],
        "input_tokens":2000,
        "output_tokens":300,
        "cache_read_tokens":40000,
        "cache_write_tokens":700
      }
      """#.utf8)
    let snapshot = try XCTUnwrap(
      CursorContextPayloadParser.stopHook(
        payload, environment: ["AGENT_TRACKER_RUN_ID": "run-1"]))
    XCTAssertEqual(snapshot.context.usedTokens, 43_000)
    XCTAssertEqual(snapshot.context.windowTokens, 1_000_000)
    XCTAssertEqual(snapshot.source, .stopHook)
  }

  func testSnapshotStoreRoundTripsAndSamplerTracksReplacement() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("CursorContext-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = AgentTrackerPaths(root: root)
    let store = try CursorContextSnapshotStore(paths: paths)
    let run = TrackedRun(
      runID: "run/with unsafe characters", harness: .cursor,
      harnessSessionID: "cursor-session")
    let sampler = ContextSampler(home: root, paths: paths)

    XCTAssertNil(sampler.sample(run))
    try store.write(
      CursorContextSnapshot(
        runID: run.runID,
        sessionID: "cursor-session",
        context: SessionContext(usedTokens: 20_000, windowTokens: 200_000, model: "composer")
      ))
    XCTAssertEqual(sampler.sample(run)?.usedTokens, 20_000)
    XCTAssertFalse(store.url(forRunID: run.runID).lastPathComponent.contains("/"))

    try store.write(
      CursorContextSnapshot(
        runID: run.runID,
        sessionID: "cursor-session",
        context: SessionContext(usedTokens: 40_000, windowTokens: 200_000, model: "composer")
      ))
    XCTAssertEqual(sampler.sample(run)?.usedTokens, 40_000)
  }

  func testSnapshotPermissionsAreOwnerOnly() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("CursorContext-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try CursorContextSnapshotStore(paths: AgentTrackerPaths(root: root))
    let snapshot = CursorContextSnapshot(
      runID: "run", sessionID: "session",
      context: SessionContext(usedTokens: 1, windowTokens: 2))
    try store.write(snapshot)
    let permissions =
      try FileManager.default.attributesOfItem(atPath: store.url(forRunID: "run").path)[
        .posixPermissions] as? NSNumber
    XCTAssertEqual(permissions?.intValue, 0o600)
  }

  func testFreshStatusLineReadingWinsOverStopHookFallback() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("CursorContext-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try CursorContextSnapshotStore(paths: AgentTrackerPaths(root: root))
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let authoritative = CursorContextSnapshot(
      runID: "run", sessionID: "session",
      context: SessionContext(usedTokens: 50_000, windowTokens: 272_000),
      source: .statusLine, updatedAt: now)
    let fallback = CursorContextSnapshot(
      runID: "run", sessionID: "session",
      context: SessionContext(usedTokens: 40_000, windowTokens: 200_000),
      source: .stopHook, updatedAt: now.addingTimeInterval(1))

    try store.write(authoritative)
    try store.write(fallback)

    XCTAssertEqual(try store.read(forRunID: "run"), authoritative)
  }
}

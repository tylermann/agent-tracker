import XCTest

@testable import AgentTrackerCore

final class EventInboxTests: XCTestCase {
  private var root: URL!
  private var inbox: EventInbox!

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("AgentTrackerInbox-\(UUID().uuidString)")
    inbox = try EventInbox(paths: AgentTrackerPaths(root: root))
  }

  override func tearDownWithError() throws {
    inbox = nil
    try? FileManager.default.removeItem(at: root)
  }

  private func event(at date: Date, runID: String = "run") -> AgentEvent {
    AgentEvent(
      occurredAt: date,
      runID: runID,
      harness: .claude,
      kind: .promptSubmitted,
      harnessSessionID: "session",
      ghosttyTerminalID: "terminal",
      processID: 123,
      cwd: "/tmp/project",
      promptPreview: "Fix it",
      detail: "detail",
      executable: "/usr/local/bin/claude",
      modelID: "fable",
      exitCode: 0
    )
  }

  func testEnqueueDecodeRoundTrip() throws {
    // Whole-second date: the inbox encodes dates as ISO8601 without fractional seconds.
    let original = event(at: Date(timeIntervalSince1970: 1_700_000_000))
    try inbox.enqueue(original)

    let pending = try inbox.pendingURLs()
    XCTAssertEqual(pending.count, 1)
    XCTAssertEqual(pending[0].pathExtension, "json")
    XCTAssertTrue(pending[0].lastPathComponent.contains(original.eventID.uuidString))

    let decoded = try inbox.decode(at: pending[0])
    XCTAssertEqual(decoded, original)

    try inbox.remove(at: pending[0])
    XCTAssertEqual(try inbox.pendingURLs(), [])
  }

  func testWireFormatKeys() throws {
    let original = event(at: Date(timeIntervalSince1970: 1_700_000_000))
    try inbox.enqueue(original)
    let url = try XCTUnwrap(try inbox.pendingURLs().first)
    let root = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    XCTAssertEqual(
      Set(root.keys),
      [
        "schemaVersion", "eventID", "occurredAt", "runID", "harness", "kind",
        "harnessSessionID", "ghosttyTerminalID", "processID", "cwd", "promptPreview",
        "detail", "executable", "modelID", "exitCode",
      ])
    XCTAssertEqual(root["schemaVersion"] as? Int, 1)
    XCTAssertEqual(root["harness"] as? String, "claude")
    XCTAssertEqual(root["kind"] as? String, "promptSubmitted")
  }

  func testPendingURLsAreOrderedByOccurrence()
    throws
  {
    let base = Date(timeIntervalSince1970: 1_700_000_000)
    let later = event(at: base.addingTimeInterval(5), runID: "later")
    let earlier = event(at: base, runID: "earlier")
    try inbox.enqueue(later)
    try inbox.enqueue(earlier)

    let decoded = try inbox.pendingURLs().map { try inbox.decode(at: $0) }
    XCTAssertEqual(decoded.map(\.runID), ["earlier", "later"])
  }

  func testEnqueuedFilesHaveOwnerOnlyPermissions() throws {
    try inbox.enqueue(event(at: Date(timeIntervalSince1970: 1_700_000_000)))
    let url = try XCTUnwrap(try inbox.pendingURLs().first)
    let permissions =
      try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]
      as? NSNumber
    XCTAssertEqual(permissions?.intValue, 0o600)
  }
}

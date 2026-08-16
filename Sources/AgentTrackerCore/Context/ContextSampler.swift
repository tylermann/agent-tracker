import Foundation

/// Samples each tracked run's context occupancy from its transcript or local callback snapshot.
///
/// Built for a caller that ticks often: a run is re-read only when its source file's size or
/// modification date has changed, so a steady-state refresh costs one `stat` per row. Source bytes
/// are parsed and dropped — only the resulting token counts are kept.
public final class ContextSampler {
  /// Transcripts are appended to, so the answer is near the end. Reading a window rather than the
  /// file keeps the cost flat as a session grows into tens of megabytes.
  private static let initialTailBytes = 256 * 1024
  /// One assistant turn can be followed by megabytes of tool results, pushing the line we need
  /// past the first window. Escalate once, then give up rather than read an unbounded amount.
  private static let maximumTailBytes = 4 * 1024 * 1024
  /// A transcript-backed session that has not written its archive yet must not re-scan it on every
  /// tick.
  private static let relocateInterval: TimeInterval = 15

  private struct Entry {
    var url: URL?
    var locatedAt: Date
    var size: Int?
    var modifiedAt: Date?
    var context: SessionContext?
  }

  private let home: URL
  private let fileManager: FileManager
  private let cursorSnapshots: CursorContextSnapshotStore?
  private var entries: [String: Entry] = [:]

  public init(
    home: URL = FileManager.default.homeDirectoryForCurrentUser,
    fileManager: FileManager = .default,
    paths: AgentTrackerPaths = AgentTrackerPaths()
  ) {
    self.home = home
    self.fileManager = fileManager
    cursorSnapshots = try? CursorContextSnapshotStore(paths: paths, fileManager: fileManager)
  }

  /// The run's context occupancy, or nil when the harness records none, the transcript has not
  /// been located, or no model turn has been served yet.
  public func sample(_ run: TrackedRun, now: Date = Date()) -> SessionContext? {
    if run.harness == .cursor { return sampleCursor(run) }
    guard let sessionID = run.harnessSessionID, !sessionID.isEmpty else { return nil }
    var entry = entries[run.runID] ?? Entry(url: nil, locatedAt: .distantPast)

    if entry.url == nil {
      guard now.timeIntervalSince(entry.locatedAt) >= Self.relocateInterval else {
        return entry.context
      }
      entry.locatedAt = now
      entry.url = TranscriptLocator.url(
        harness: run.harness, sessionID: sessionID, home: home, fileManager: fileManager)
      entries[run.runID] = entry
    }
    guard let url = entry.url else { return entry.context }

    guard let attributes = try? fileManager.attributesOfItem(atPath: url.path) else {
      // The transcript was moved or deleted; fall back to relocating it on the next interval.
      entry.url = nil
      entry.locatedAt = now
      entries[run.runID] = entry
      return entry.context
    }
    let size = (attributes[.size] as? NSNumber)?.intValue
    let modifiedAt = attributes[.modificationDate] as? Date
    guard size != entry.size || modifiedAt != entry.modifiedAt else { return entry.context }

    entry.size = size
    entry.modifiedAt = modifiedAt
    if let context = readContext(harness: run.harness, url: url) {
      entry.context = context
    }
    entries[run.runID] = entry
    return entry.context
  }

  /// Cursor reports context through a configured status-line callback rather than its transcript.
  /// The URL is deterministic, so a not-yet-created snapshot can be retried on every cheap refresh
  /// instead of waiting for the transcript archive's relocation interval.
  private func sampleCursor(_ run: TrackedRun) -> SessionContext? {
    guard let cursorSnapshots else { return nil }
    var entry = entries[run.runID] ?? Entry(url: nil, locatedAt: .distantPast)
    let url = cursorSnapshots.url(forRunID: run.runID)
    entry.url = url
    guard let attributes = try? fileManager.attributesOfItem(atPath: url.path) else {
      entries[run.runID] = entry
      return entry.context
    }
    let size = (attributes[.size] as? NSNumber)?.intValue
    let modifiedAt = attributes[.modificationDate] as? Date
    guard size != entry.size || modifiedAt != entry.modifiedAt else { return entry.context }
    entry.size = size
    entry.modifiedAt = modifiedAt
    if let snapshot = try? cursorSnapshots.read(forRunID: run.runID) {
      entry.context = snapshot.context
    }
    entries[run.runID] = entry
    return entry.context
  }

  /// Drops cached state for runs that are no longer on screen, so a long-lived session's cache
  /// cannot grow without bound.
  public func retain(runIDs: Set<String>) {
    guard !entries.keys.allSatisfy(runIDs.contains) else { return }
    entries = entries.filter { runIDs.contains($0.key) }
  }

  private func readContext(harness: Harness, url: URL) -> SessionContext? {
    var window = Self.initialTailBytes
    while true {
      guard let (data, reachedStart) = tail(of: url, maxBytes: window) else { return nil }
      let newline = UInt8(ascii: "\n")
      let lines: [Data] = data.split(separator: newline).map { Data($0) }
      if let context = TranscriptContextParser.parse(harness: harness, lines: lines) {
        return context
      }
      guard !reachedStart, window < Self.maximumTailBytes else { return nil }
      window = min(window * 8, Self.maximumTailBytes)
    }
  }

  /// The last `maxBytes` of the file, plus whether that covered the whole thing. The first line is
  /// usually cut mid-record; it simply fails to parse, which is why no boundary trimming is needed.
  private func tail(of url: URL, maxBytes: Int) -> (data: Data, reachedStart: Bool)? {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    guard let end = try? handle.seekToEnd() else { return nil }
    let offset = end > UInt64(maxBytes) ? end - UInt64(maxBytes) : 0
    guard (try? handle.seek(toOffset: offset)) != nil, let data = try? handle.readToEnd() else {
      return nil
    }
    return (data, offset == 0)
  }
}

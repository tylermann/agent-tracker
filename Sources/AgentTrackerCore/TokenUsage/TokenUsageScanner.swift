import Foundation

/// Incrementally folds harness transcripts into per-day token counters.
///
/// Transcripts are append-only JSON Lines, so each file is resumed from the byte offset the last
/// scan committed and only new bytes are parsed. The scanner does file IO only: callers read scan
/// states from the store first and commit the returned deltas afterwards, so no IO ever happens
/// under the store lock. A first run (no states) is simply "offset zero for every file", which
/// backfills the full on-disk history.
public final class TokenUsageScanner {
  public struct ScanResult: Sendable {
    public var deltas: [TokenUsageRow]
    public var states: [TokenUsageScanState]
    public var removedPaths: [String]

    public init(deltas: [TokenUsageRow], states: [TokenUsageScanState], removedPaths: [String]) {
      self.deltas = deltas
      self.states = states
      self.removedPaths = removedPaths
    }
  }

  private struct BucketKey: Hashable {
    var day: String
    var harness: Harness
    var model: String
  }

  private static let chunkSize = 4 << 20

  private let home: URL
  private let fileManager: FileManager
  private let calendar: Calendar

  public init(
    home: URL = FileManager.default.homeDirectoryForCurrentUser,
    fileManager: FileManager = .default,
    calendar: Calendar = .current
  ) {
    self.home = home
    self.fileManager = fileManager
    self.calendar = calendar
  }

  public func scan(states: [String: TokenUsageScanState]) -> ScanResult {
    var buckets: [BucketKey: TokenUsageCounters] = [:]
    var changedStates: [TokenUsageScanState] = []
    var seenPaths = Set<String>()

    for url in claudeTranscripts() + codexTranscripts() {
      let harness: Harness = url.path.contains("/.codex/") ? .codex : .claude
      seenPaths.insert(url.path)
      if let state = scanFile(at: url, harness: harness, previous: states[url.path], into: &buckets)
      {
        changedStates.append(state)
      }
    }

    let removed = states.keys.filter { path in
      !seenPaths.contains(path) && path != TokenUsageScanState.cursorEventsPath
    }
    let deltas = buckets.map { key, counters in
      TokenUsageRow(day: key.day, harness: key.harness, model: key.model, counters: counters)
    }
    return ScanResult(deltas: deltas, states: changedStates, removedPaths: removed.sorted())
  }

  /// `~/.claude/projects/<slug>/<session>.jsonl` — one level of project directories.
  private func claudeTranscripts() -> [URL] {
    let projects = home.appendingPathComponent(".claude/projects", isDirectory: true)
    return children(of: projects).flatMap { jsonlFiles(in: $0) }
  }

  /// `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` — three levels of date directories.
  private func codexTranscripts() -> [URL] {
    let sessions = home.appendingPathComponent(".codex/sessions", isDirectory: true)
    return children(of: sessions)
      .flatMap { children(of: $0) }
      .flatMap { children(of: $0) }
      .flatMap { jsonlFiles(in: $0) }
  }

  private func children(of directory: URL) -> [URL] {
    (try? fileManager.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
  }

  private func jsonlFiles(in directory: URL) -> [URL] {
    children(of: directory).filter { $0.pathExtension == "jsonl" }
  }

  /// Returns the state to commit, or nil when the file is unchanged since the previous scan.
  private func scanFile(
    at url: URL,
    harness: Harness,
    previous: TokenUsageScanState?,
    into buckets: inout [BucketKey: TokenUsageCounters]
  ) -> TokenUsageScanState? {
    let path = url.path
    guard let attributes = try? fileManager.attributesOfItem(atPath: path),
      let size = (attributes[.size] as? NSNumber)?.intValue
    else { return nil }
    let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
    if let previous, previous.fileSize == size, previous.modifiedAt == modified {
      return nil
    }

    var model = previous?.model
    let offset = previous?.byteOffset ?? 0
    if size < offset {
      // Shrunk or rewritten in place. The already-counted bytes cannot be distinguished from new
      // ones, so skip to the end rather than ever double-counting.
      return TokenUsageScanState(
        path: path, byteOffset: size, fileSize: size, modifiedAt: modified, model: model)
    }

    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    guard (try? handle.seek(toOffset: UInt64(offset))) != nil else { return nil }

    var consumedOffset = offset
    var pending = Data()
    while let chunk = try? handle.read(upToCount: Self.chunkSize), !chunk.isEmpty {
      pending.append(chunk)
      var lineStart = pending.startIndex
      while let newline = pending[lineStart...].firstIndex(of: 0x0A) {
        process(
          line: pending.subdata(in: lineStart..<newline),
          harness: harness,
          model: &model,
          into: &buckets
        )
        lineStart = pending.index(after: newline)
      }
      consumedOffset += pending.distance(from: pending.startIndex, to: lineStart)
      // A partial trailing line stays pending; if the file ends without a newline it is left for
      // the next scan, which re-reads from this offset once the writer finishes the line.
      pending = Data(pending[lineStart...])
    }

    return TokenUsageScanState(
      path: path, byteOffset: consumedOffset, fileSize: size, modifiedAt: modified, model: model)
  }

  private func process(
    line: Data,
    harness: Harness,
    model: inout String?,
    into buckets: inout [BucketKey: TokenUsageCounters]
  ) {
    let sample: TokenUsageLineParser.Sample?
    switch harness {
    case .claude:
      sample = TokenUsageLineParser.claude(line: line)
    case .codex:
      switch TokenUsageLineParser.codex(line: line) {
      case .model(let name):
        model = name
        sample = nil
      case .sample(let parsed):
        sample = parsed
      case nil:
        sample = nil
      }
    case .cursor:
      sample = nil
    }
    guard let sample else { return }
    let key = BucketKey(
      day: TokenUsageDayKey.day(for: sample.date, calendar: calendar),
      harness: harness,
      model: TokenUsageModelKey.normalized(sample.model ?? model)
    )
    buckets[key, default: TokenUsageCounters()] += sample.counters
  }
}

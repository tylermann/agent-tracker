import AgentTrackerCore
import Foundation
import os

/// Runs token-usage history cycles off the main actor and serializes them, so a slow first
/// backfill and the periodic rescans can never interleave their store writes.
actor TokenUsageHistoryCoordinator {
  private static let cursorBackfillDays = 90
  /// Cursor days re-fetched every cycle. Replacing a trailing window keeps the sync idempotent
  /// and heals events that arrive late or out of order.
  private static let cursorResyncDays = 2
  /// Published range: 13 weeks covers both chart granularities.
  private static let publishedDays = 98

  private let scanner = TokenUsageScanner()
  /// The Cursor feed is an undocumented endpoint that fails silently by design (the meters row
  /// already shows provider state), so the log is the only place a format change would show up.
  private let logger = Logger(subsystem: "com.tyler.agenttracker", category: "token-usage")

  /// One full cycle: incremental local transcript scan, then the Cursor usage-event window,
  /// then a re-read of the rows the chart plots. Returns nil when the store is unavailable.
  func runCycle(store: RunStore, now: Date = Date()) async -> [TokenUsageRow]? {
    let calendar = Calendar.current
    do {
      let states = try store.tokenUsageScanStates()
      let result = scanner.scan(states: states)
      try store.recordTokenUsage(deltas: result.deltas, states: result.states)
      try store.removeTokenUsageScanStates(paths: result.removedPaths)
      logger.notice(
        "scan cycle: \(result.deltas.count) deltas across \(result.states.count) changed files")
      await syncCursor(store: store, states: states, now: now, calendar: calendar)
      let sinceDay = TokenUsageDayKey.day(
        for: now.addingTimeInterval(-Double(Self.publishedDays) * 86_400), calendar: calendar)
      return try store.tokenUsage(sinceDay: sinceDay)
    } catch {
      logger.error("scan cycle failed: \(error.localizedDescription)")
      return nil
    }
  }

  /// Cursor keeps no local token counts, so its rows come from the dashboard's usage-event feed.
  /// Failures (signed out, offline, format change) skip the cycle silently — the usage meter row
  /// already surfaces the provider's state, and local scanning must not depend on the network.
  private func syncCursor(
    store: RunStore, states: [String: TokenUsageScanState], now: Date, calendar: Calendar
  ) async {
    let start: Date
    if states[TokenUsageScanState.cursorEventsPath] == nil {
      start = now.addingTimeInterval(-Double(Self.cursorBackfillDays) * 86_400)
    } else {
      start = calendar.startOfDay(
        for: now.addingTimeInterval(-Double(Self.cursorResyncDays) * 86_400))
    }
    let events: [CursorUsageEvent]
    do {
      events = try await UsageFetcher.fetchCursorUsageEvents(
        startMs: Int64(start.timeIntervalSince1970 * 1_000),
        endMs: Int64(now.timeIntervalSince1970 * 1_000))
    } catch {
      logger.notice(
        "Cursor usage-event sync skipped: \(error.localizedDescription, privacy: .public)")
      return
    }
    logger.notice("Cursor usage-event sync fetched \(events.count) events")

    var days: [String] = []
    var cursor = calendar.startOfDay(for: start)
    while cursor <= now {
      days.append(TokenUsageDayKey.day(for: cursor, calendar: calendar))
      guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
      cursor = next
    }
    let state = TokenUsageScanState(
      path: TokenUsageScanState.cursorEventsPath,
      byteOffset: 0,
      fileSize: 0,
      modifiedAt: now.timeIntervalSince1970,
      model: days.last
    )
    try? store.replaceTokenUsage(
      harness: .cursor,
      days: days,
      rows: CursorUsageEvent.dailyRows(from: events, calendar: calendar),
      state: state
    )
  }
}

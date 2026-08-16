import AgentTrackerCore
import AppKit
import Combine
import Darwin
import Foundation

@MainActor
final class AgentTrackerModel: ObservableObject {
  static let recentPageSize = 10

  @Published private(set) var runs: [TrackedRun] = []
  @Published private(set) var recentTotalCount = 0
  @Published var errorMessage: String?
  @Published private(set) var usageSnapshots: [ProviderUsageSnapshot] = []
  @Published var usageMetersEnabled: Bool {
    didSet {
      UserDefaults.standard.set(usageMetersEnabled, forKey: PreferenceKeys.usageMetersEnabled)
      configureUsagePolling()
    }
  }
  @Published var isDetached: Bool {
    didSet { UserDefaults.standard.set(isDetached, forKey: PreferenceKeys.panelDetached) }
  }
  /// Run highlighted for keyboard navigation, or `nil` when the sidebar is not in keyboard mode.
  /// Tracked by run ID rather than row index so the highlight follows a run across the refreshes
  /// that reorder and regroup rows every 0.75s.
  @Published var selectedRunID: String?
  /// Runs whose prompt preview is expanded to show more of the opening prompt. Keyed by run ID so
  /// the expansion follows a run across the refreshes that reorder and regroup rows.
  @Published private(set) var expandedRunIDs: Set<String> = []
  /// Owned by the model rather than the view so keyboard navigation can walk the Recent rows only
  /// while they are actually on screen.
  @Published var recentExpanded = false {
    didSet {
      recentLimit = recentExpanded ? Self.recentPageSize : 0
      refresh()
    }
  }

  var onAttention: ((TrackedRun, AgentEventKind) -> Void)?

  private var inbox: EventInbox?
  private var store: RunStore?
  private var timer: Timer?
  private var usageTask: Task<Void, Never>?
  private var lastGoodUsage: [Harness: ProviderUsageSnapshot] = [:]
  private var distributedObserver: NSObjectProtocol?
  private var didReconcile = false
  private var isStarted = false
  private var isRefreshing = false
  private var recentLimit = 0
  /// Terminal-focus failures are feedback for a single click, not a persistent app state. Keep
  /// their dismissal task separate from storage and integration errors, which remain visible.
  private var transientErrorTask: Task<Void, Never>?

  init() {
    isDetached = UserDefaults.standard.bool(forKey: PreferenceKeys.panelDetached)
    usageMetersEnabled = UserDefaults.standard.bool(forKey: PreferenceKeys.usageMetersEnabled)
    do {
      inbox = try EventInbox()
      store = try RunStore()
    } catch {
      errorMessage = "Unable to initialize Agent Tracker storage: \(error.localizedDescription)"
    }
  }

  var unreadCount: Int { runs.filter(\.unreadAttention).count }
  var needsYou: [TrackedRun] {
    runs.filter { $0.status == .needsAttention || $0.status == .waiting }
  }
  var working: [TrackedRun] { runs.filter { $0.status == .working } }
  var idle: [TrackedRun] { runs.filter { $0.status == .starting } }
  var recent: [TrackedRun] { runs.filter { $0.status == .ended || $0.status == .unavailable } }
  var hasMoreRecent: Bool { recent.count < recentTotalCount }
  var remainingRecentCount: Int { max(recentTotalCount - recent.count, 0) }

  /// Rows the arrow keys walk, in the order they are drawn in the sidebar.
  var navigableRuns: [TrackedRun] {
    needsYou + working + idle + (recentExpanded ? recent : [])
  }

  /// Selects a starting row when entering keyboard mode, keeping any still-visible selection.
  func beginKeyboardSelection() {
    let candidates = navigableRuns
    if let selectedRunID, candidates.contains(where: { $0.runID == selectedRunID }) { return }
    selectedRunID = candidates.first?.runID
  }

  func endKeyboardSelection() {
    selectedRunID = nil
  }

  /// Moves the highlight by `delta` rows, clamping at the ends rather than wrapping.
  func moveSelection(by delta: Int) {
    let candidates = navigableRuns
    guard !candidates.isEmpty else { return }
    guard let selectedRunID,
      let index = candidates.firstIndex(where: { $0.runID == selectedRunID })
    else {
      self.selectedRunID = delta < 0 ? candidates.last?.runID : candidates.first?.runID
      return
    }
    let target = min(max(index + delta, 0), candidates.count - 1)
    self.selectedRunID = candidates[target].runID
  }

  func isExpanded(_ run: TrackedRun) -> Bool { expandedRunIDs.contains(run.runID) }

  func toggleExpanded(_ run: TrackedRun) {
    if expandedRunIDs.contains(run.runID) {
      expandedRunIDs.remove(run.runID)
    } else {
      expandedRunIDs.insert(run.runID)
    }
  }

  /// Expands the highlighted run's prompt preview, exactly as clicking its disclosure chevron does.
  func expandSelection() {
    guard let selectedRunID else { return }
    expandedRunIDs.insert(selectedRunID)
  }

  func collapseSelection() {
    guard let selectedRunID else { return }
    expandedRunIDs.remove(selectedRunID)
  }

  /// Focuses the highlighted run, exactly as clicking its row does. Returns `false` when nothing is
  /// selected, so the caller can leave keyboard mode running.
  @discardableResult
  func activateSelection() -> Bool {
    guard let selectedRunID, let run = runs.first(where: { $0.runID == selectedRunID }) else {
      return false
    }
    focus(run)
    return true
  }

  func start() {
    isStarted = true
    distributedObserver = DistributedNotificationCenter.default().addObserver(
      forName: AgentTrackerNotification.inboxChanged,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor in self?.refresh() }
    }
    timer = Timer.scheduledTimer(withTimeInterval: 0.75, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.refresh() }
    }
    refresh()
    configureUsagePolling()
  }

  func stop() {
    isStarted = false
    timer?.invalidate()
    usageTask?.cancel()
    usageTask = nil
    if let distributedObserver {
      DistributedNotificationCenter.default().removeObserver(distributedObserver)
    }
  }

  func refreshUsage() {
    guard usageMetersEnabled else { return }
    startUsagePolling(forceCredentialReload: true)
  }

  func refresh() {
    // Git metadata lookup launches a short-lived subprocess whose wait can service the main run
    // loop. Coalesce timer and inbox notifications that arrive during a refresh so they cannot
    // recursively process the same event.
    guard !isRefreshing else { return }
    isRefreshing = true
    defer { isRefreshing = false }

    guard let inbox, let store else { return }
    do {
      for url in try inbox.pendingURLs() {
        do {
          let event = try inbox.decode(at: url)
          var run = try store.apply(event)
          if event.kind == .attentionRequired || event.kind == .turnStopped,
            let terminalID = run.ghosttyTerminalID,
            GhosttyAutomation.isFocused(terminalID: terminalID)
          {
            try store.markSeen(runID: run.runID)
            run.unreadAttention = false
          } else if event.kind == .attentionRequired || event.kind == .turnStopped {
            onAttention?(run, event.kind)
          }
          try inbox.remove(at: url)
        } catch {
          let failed = url.appendingPathExtension("failed")
          try? FileManager.default.moveItem(at: url, to: failed)
          errorMessage = error.localizedDescription
        }
      }
      if !didReconcile {
        try reconcileProcesses()
        try store.prune(olderThan: Date().addingTimeInterval(-7 * 86_400))
        didReconcile = true
      }
      let runList = try store.runList(recentLimit: recentLimit)
      runs = runList.runs
      recentTotalCount = runList.recentCount
      // Drop expansion state for runs that scrolled out of the list so the set cannot grow without
      // bound over a long session.
      let visibleIDs = Set(runList.runs.map(\.runID))
      if !expandedRunIDs.isSubset(of: visibleIDs) {
        expandedRunIDs.formIntersection(visibleIDs)
      }
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func focus(_ run: TrackedRun) {
    guard let store else {
      errorMessage = "Agent Tracker storage is unavailable."
      return
    }
    guard let terminalID = run.ghosttyTerminalID else {
      showTransientError(
        "This run has no Ghostty terminal link, so it cannot be focused. If it has stopped, mark it as unavailable."
      )
      return
    }
    do {
      try GhosttyAutomation.focus(terminalID: terminalID)
      try store.markSeen(runID: run.runID)
      dismissError()
      refresh()
    } catch {
      try? store.markUnavailable(runID: run.runID)
      showTransientError(error.localizedDescription)
      refresh()
    }
  }

  /// Reopens an ended run's harness session in a new Ghostty terminal at the run's directory.
  func resume(_ run: TrackedRun) {
    guard let command = ResumeCommand.command(for: run) else {
      showTransientError("This run did not record a session ID, so it cannot be resumed.")
      return
    }
    do {
      try GhosttyAutomation.openTab(
        command: command,
        workingDirectory: run.workingDirectory ?? run.projectRoot
      )
      dismissError()
    } catch {
      showTransientError(error.localizedDescription)
    }
  }

  /// An event-only run has no wrapper PID to reconcile, so this is an explicit user decision
  /// rather than an automatic timeout that could hide genuinely long-running work.
  func markUnavailable(_ run: TrackedRun) {
    guard run.ghosttyTerminalID == nil, let store else { return }
    do {
      try store.markUnavailable(runID: run.runID)
      dismissError()
      refresh()
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func dismissError() {
    transientErrorTask?.cancel()
    transientErrorTask = nil
    errorMessage = nil
  }

  func clearHistory() {
    guard let store else { return }
    do {
      try store.clearHistory()
      refresh()
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func showMoreRecent() {
    guard recentExpanded, hasMoreRecent else { return }
    recentLimit += Self.recentPageSize
    refresh()
  }

  private func showTransientError(_ message: String) {
    transientErrorTask?.cancel()
    errorMessage = message
    transientErrorTask = Task { [weak self] in
      try? await Task.sleep(nanoseconds: 6_000_000_000)
      guard !Task.isCancelled, self?.errorMessage == message else { return }
      self?.errorMessage = nil
      self?.transientErrorTask = nil
    }
  }

  private func reconcileProcesses() throws {
    guard let store else { return }
    for run in try store.activeRuns() {
      guard let pid = run.processID else { continue }
      errno = 0
      if kill(pid, 0) != 0, errno == ESRCH {
        try store.markUnavailable(runID: run.runID)
      }
    }
  }

  private func configureUsagePolling() {
    guard isStarted else { return }
    if usageMetersEnabled {
      startUsagePolling()
    } else {
      usageTask?.cancel()
      usageTask = nil
      usageSnapshots = []
      lastGoodUsage = [:]
      Task { await UsageFetcher.clearCredentialCache() }
    }
  }

  private func startUsagePolling(forceCredentialReload: Bool = false) {
    usageTask?.cancel()
    usageTask = Task { [weak self] in
      var shouldReloadCredentials = forceCredentialReload
      while !Task.isCancelled {
        let results = await UsageFetcher.fetchAll(
          forceCredentialReload: shouldReloadCredentials)
        shouldReloadCredentials = false
        guard !Task.isCancelled else { return }
        self?.acceptUsage(results)
        do {
          try await Task.sleep(for: .seconds(180))
        } catch {
          return
        }
      }
    }
  }

  private func acceptUsage(_ results: [ProviderUsageSnapshot]) {
    usageSnapshots = UsageStalenessFilter.merge(results: results, lastGood: &lastGoodUsage)
  }
}

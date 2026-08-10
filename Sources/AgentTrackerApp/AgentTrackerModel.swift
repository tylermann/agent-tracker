import AgentTrackerCore
import AppKit
import Combine
import Darwin
import Foundation

@MainActor
final class AgentTrackerModel: ObservableObject {
  @Published private(set) var runs: [TrackedRun] = []
  @Published var errorMessage: String?
  @Published var isDetached: Bool {
    didSet { UserDefaults.standard.set(isDetached, forKey: "panelDetached") }
  }

  var onAttention: ((TrackedRun, AgentEventKind) -> Void)?

  private var inbox: EventInbox?
  private var store: RunStore?
  private var timer: Timer?
  private var distributedObserver: NSObjectProtocol?
  private var didReconcile = false

  init() {
    isDetached = UserDefaults.standard.bool(forKey: "panelDetached")
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

  func start() {
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
  }

  func stop() {
    timer?.invalidate()
    if let distributedObserver {
      DistributedNotificationCenter.default().removeObserver(distributedObserver)
    }
  }

  func refresh() {
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
      runs = try store.runs()
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
      errorMessage = "This run is not bound to a Ghostty terminal."
      return
    }
    do {
      try GhosttyAutomation.focus(terminalID: terminalID)
      try store.markSeen(runID: run.runID)
      refresh()
    } catch {
      try? store.markUnavailable(runID: run.runID)
      errorMessage = error.localizedDescription
      refresh()
    }
  }

  func markSeen(runID: String) {
    try? store?.markSeen(runID: runID)
    refresh()
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

  private func reconcileProcesses() throws {
    guard let store else { return }
    for run in try store.runs(includeRecentSince: .distantPast) {
      guard run.endedAt == nil, let pid = run.processID else { continue }
      errno = 0
      if kill(pid, 0) != 0, errno == ESRCH {
        try store.markUnavailable(runID: run.runID)
      }
    }
  }
}

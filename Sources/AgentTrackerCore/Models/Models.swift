import Foundation

public enum Harness: String, Codable, CaseIterable, Sendable {
  case claude
  case codex
  case cursor

  public var displayName: String {
    switch self {
    case .claude: "Claude"
    case .codex: "Codex"
    case .cursor: "Cursor"
    }
  }
}

public enum AgentEventKind: String, Codable, Sendable {
  case processStarted
  case sessionStarted
  case promptSubmitted
  case activity
  case attentionRequired
  case turnStopped
  case sessionEnded
  case processExited
}

public struct AgentEvent: Codable, Equatable, Sendable {
  public var schemaVersion: Int
  public var eventID: UUID
  public var occurredAt: Date
  public var runID: String
  public var harness: Harness
  public var kind: AgentEventKind
  public var harnessSessionID: String?
  public var ghosttyTerminalID: String?
  public var processID: Int32?
  public var cwd: String?
  public var promptPreview: String?
  public var detail: String?
  public var executable: String?
  public var exitCode: Int32?

  public init(
    schemaVersion: Int = 1,
    eventID: UUID = UUID(),
    occurredAt: Date = Date(),
    runID: String,
    harness: Harness,
    kind: AgentEventKind,
    harnessSessionID: String? = nil,
    ghosttyTerminalID: String? = nil,
    processID: Int32? = nil,
    cwd: String? = nil,
    promptPreview: String? = nil,
    detail: String? = nil,
    executable: String? = nil,
    exitCode: Int32? = nil
  ) {
    self.schemaVersion = schemaVersion
    self.eventID = eventID
    self.occurredAt = occurredAt
    self.runID = runID
    self.harness = harness
    self.kind = kind
    self.harnessSessionID = harnessSessionID
    self.ghosttyTerminalID = ghosttyTerminalID
    self.processID = processID
    self.cwd = cwd
    self.promptPreview = promptPreview
    self.detail = detail
    self.executable = executable
    self.exitCode = exitCode
  }
}

public enum RunStatus: String, Codable, CaseIterable, Sendable {
  case starting
  case working
  case needsAttention
  case waiting
  case ended
  case unavailable

  public var displayName: String {
    switch self {
    case .starting: "Starting"
    case .working: "Working"
    case .needsAttention: "Needs attention"
    case .waiting: "Waiting"
    case .ended: "Ended"
    case .unavailable: "Unavailable"
    }
  }
}

public struct TrackedRun: Identifiable, Codable, Equatable, Sendable {
  public var id: String { runID }
  public var runID: String
  public var harness: Harness
  public var harnessSessionID: String?
  public var ghosttyTerminalID: String?
  public var executable: String?
  public var processID: Int32?
  public var projectRoot: String?
  public var workingDirectory: String?
  public var branch: String?
  public var gitDiffstat: GitDiffstat?
  public var promptPreview: String?
  public var status: RunStatus
  public var unreadAttention: Bool
  public var startedAt: Date
  public var lastEventAt: Date
  public var endedAt: Date?
  public var exitCode: Int32?

  public init(
    runID: String,
    harness: Harness,
    harnessSessionID: String? = nil,
    ghosttyTerminalID: String? = nil,
    executable: String? = nil,
    processID: Int32? = nil,
    projectRoot: String? = nil,
    workingDirectory: String? = nil,
    branch: String? = nil,
    gitDiffstat: GitDiffstat? = nil,
    promptPreview: String? = nil,
    status: RunStatus = .starting,
    unreadAttention: Bool = false,
    startedAt: Date = Date(),
    lastEventAt: Date = Date(),
    endedAt: Date? = nil,
    exitCode: Int32? = nil
  ) {
    self.runID = runID
    self.harness = harness
    self.harnessSessionID = harnessSessionID
    self.ghosttyTerminalID = ghosttyTerminalID
    self.executable = executable
    self.processID = processID
    self.projectRoot = projectRoot
    self.workingDirectory = workingDirectory
    self.branch = branch
    self.gitDiffstat = gitDiffstat
    self.promptPreview = promptPreview
    self.status = status
    self.unreadAttention = unreadAttention
    self.startedAt = startedAt
    self.lastEventAt = lastEventAt
    self.endedAt = endedAt
    self.exitCode = exitCode
  }
}

public enum AgentTrackerNotification {
  public static let inboxChanged = Notification.Name("com.agenttracker.inbox-changed")
}

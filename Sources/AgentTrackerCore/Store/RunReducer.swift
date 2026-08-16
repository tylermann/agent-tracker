import Foundation

/// The run state machine: folds one event into a run's status and metadata. Pure domain logic —
/// no persistence concerns.
enum RunReducer {
  static func reduce(_ event: AgentEvent, into run: inout TrackedRun) {
    // Cursor emits both native and Claude Code-compatible hooks. Once a native Cursor event
    // identifies the shared run, do not let a later compatibility event relabel it as Claude or
    // replace native metadata with the directory from which the compatibility hook was loaded.
    let acceptsHarnessMetadata = run.harness != .cursor || event.harness == .cursor
    if acceptsHarnessMetadata {
      run.harness = event.harness
      run.workingDirectory = event.cwd ?? run.workingDirectory
    }
    run.harnessSessionID = event.harnessSessionID ?? run.harnessSessionID
    run.ghosttyTerminalID = event.ghosttyTerminalID ?? run.ghosttyTerminalID
    run.executable = event.executable ?? run.executable
    run.processID = event.processID ?? run.processID
    if run.promptPreview == nil, let preview = event.promptPreview, !preview.isEmpty {
      run.promptPreview = preview
    }
    run.lastEventAt = max(run.lastEventAt, event.occurredAt)

    // The native event is authoritative for Cursor state. Its Claude-compatible duplicate may be
    // delivered afterward and otherwise turn an approval wait back into ordinary activity.
    guard acceptsHarnessMetadata else { return }

    switch event.kind {
    case .processStarted, .sessionStarted:
      if run.status == .starting || run.status == .ended || run.status == .unavailable {
        run.status = .starting
      }
      run.workingSince = nil
      run.endedAt = nil
    case .promptSubmitted, .activity:
      // Only the transition into working starts the clock. Every later tool call in the same turn
      // leaves it alone, which is what makes the row report the length of the run rather than the
      // gap between two tool calls. The nil check re-seeds rows stored before this was tracked.
      if run.status != .working || run.workingSince == nil {
        run.workingSince = event.occurredAt
      }
      run.status = .working
      run.unreadAttention = false
      run.endedAt = nil
    case .attentionRequired:
      finishTurn(&run, at: event.occurredAt)
      run.status = .needsAttention
      run.unreadAttention = true
    case .turnStopped:
      finishTurn(&run, at: event.occurredAt)
      run.status = .waiting
      run.unreadAttention = true
    case .sessionEnded, .processExited:
      finishTurn(&run, at: event.occurredAt)
      run.status = .ended
      run.unreadAttention = false
      run.endedAt = event.occurredAt
      run.exitCode = event.exitCode ?? run.exitCode
    }
  }

  /// Freezes the working stretch that just ended. A run that was already blocked keeps the duration
  /// of its previous turn: a permission prompt arriving twice in a row must not report zero.
  private static func finishTurn(_ run: inout TrackedRun, at date: Date) {
    guard let workingSince = run.workingSince else { return }
    run.lastTurnDuration = max(0, date.timeIntervalSince(workingSince))
    run.workingSince = nil
  }
}

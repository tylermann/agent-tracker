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
      run.endedAt = nil
    case .promptSubmitted, .activity:
      run.status = .working
      run.unreadAttention = false
      run.endedAt = nil
    case .attentionRequired:
      run.status = .needsAttention
      run.unreadAttention = true
    case .turnStopped:
      run.status = .waiting
      run.unreadAttention = true
    case .sessionEnded, .processExited:
      run.status = .ended
      run.unreadAttention = false
      run.endedAt = event.occurredAt
      run.exitCode = event.exitCode ?? run.exitCode
    }
  }
}

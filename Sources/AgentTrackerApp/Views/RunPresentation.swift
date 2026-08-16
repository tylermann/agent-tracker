import AgentTrackerCore
import SwiftUI

/// Pure presentation helpers shared by the sidebar and the status-bar menu: naming, colors, and
/// usage-meter formatting. No view state.
enum RunPresentation {
  static func projectName(_ run: TrackedRun) -> String {
    let path = run.projectRoot ?? run.workingDirectory
    return path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Unknown project"
  }

  static func statusColor(_ status: RunStatus) -> Color {
    switch status {
    case .starting: .gray
    case .working: .blue
    case .needsAttention, .waiting: .orange
    case .ended: .secondary
    case .unavailable: .red
    }
  }

  static func rowBackground(_ run: TrackedRun, isSelected: Bool) -> Color {
    if isSelected { return Color.accentColor.opacity(0.16) }
    switch run.status {
    case .needsAttention, .waiting: return Color.orange.opacity(run.unreadAttention ? 0.14 : 0.1)
    case .working: return Color.blue.opacity(0.06)
    case .starting, .ended, .unavailable: return Color.primary.opacity(0.045)
    }
  }

  /// Compact duration ("49s", "2m", "1h 5m", "3d") for the row header, where it sits inline with
  /// the status and the panel is at its narrowest. `Text(_:style:.relative)` spells the same thing
  /// out as "2 min, 5 sec", which is too wide for that slot.
  static func durationLabel(_ interval: TimeInterval) -> String {
    let seconds = max(0, Int(interval))
    if seconds < 60 { return "\(seconds)s" }
    let minutes = seconds / 60
    if minutes < 60 { return "\(minutes)m" }
    let hours = minutes / 60
    if hours < 24 {
      let trailingMinutes = minutes % 60
      return trailingMinutes == 0 ? "\(hours)h" : "\(hours)h \(trailingMinutes)m"
    }
    return "\(hours / 24)d"
  }

  /// How long the agent has been running, or how long its last run took. Nil when there is nothing
  /// meaningful to report — a run that is starting up, or one stored before turn timing existed.
  ///
  /// A working run counts up from the moment it started working; every other status shows the
  /// frozen length of the stretch that just finished, labelled so it cannot be misread as the time
  /// the run has spent waiting on you.
  static func turnTiming(_ run: TrackedRun, now: Date = Date()) -> (label: String, help: String)? {
    if run.status == .working, let workingSince = run.workingSince {
      let duration = durationLabel(now.timeIntervalSince(workingSince))
      return (duration, "Running for \(duration)")
    }
    guard run.status != .working, run.status != .starting, let lastTurn = run.lastTurnDuration
    else { return nil }
    let duration = durationLabel(lastTurn)
    return ("ran \(duration)", "Its last run took \(duration)")
  }

  static func resetLabel(_ date: Date) -> String {
    let calendar = Calendar.current
    if calendar.isDateInToday(date) {
      return "Resets today at \(date.formatted(date: .omitted, time: .shortened))"
    }
    if calendar.isDateInTomorrow(date) {
      return "Resets tomorrow at \(date.formatted(date: .omitted, time: .shortened))"
    }
    return "Resets \(date.formatted(date: .abbreviated, time: .shortened))"
  }

  struct MeterDisplay {
    var label: String
    var value: String
    var fraction: Double
    var color: Color
  }

  static func meterDisplay(window: UsageWindow, overage: UsageOverage?) -> MeterDisplay {
    if let overage, overage.isEnabled, let used = overage.usedPercent {
      return MeterDisplay(
        label: "Overage",
        value: "\(Int(used.rounded()))% used",
        fraction: min(max(used / 100, 0), 1),
        color: .purple
      )
    }
    let remaining = window.remainingPercent
    let color: Color = remaining <= 10 ? .red : remaining <= 30 ? .orange : .green
    return MeterDisplay(
      label: window.label,
      value: "\(Int(remaining.rounded()))% left",
      fraction: min(max(window.usedPercent / 100, 0), 1),
      color: color
    )
  }

  /// Deliberately muted: the context bar sits on every row, so it has to read as a background
  /// gauge rather than compete with the status stripe and the unread dot.
  static func contextColor(_ context: SessionContext) -> Color {
    switch context.fraction {
    case ..<0.6: Color.green.opacity(0.4)
    case ..<0.85: Color.yellow.opacity(0.45)
    default: Color.red.opacity(0.5)
    }
  }

  /// Spoken description of the bar, which carries no visible text beyond its window size.
  static func contextAccessibilityLabel(_ context: SessionContext) -> String {
    let percent = Int(context.usedPercent.rounded())
    var line =
      "Context: \(tokenLabel(context.usedTokens)) of \(tokenLabel(context.windowTokens)) used "
      + "(\(percent)%)"
    if let model = context.model { line += ", \(model)" }
    return line
  }

  /// Uppercase K/M rather than the lowercase used for durations elsewhere in a row: "1m" next to
  /// the header's "ran 3m" would read as a minute rather than a million tokens.
  static func tokenLabel(_ tokens: Int) -> String {
    if tokens < 1_000 { return "\(tokens)" }
    if tokens < 1_000_000 { return "\(tokens / 1_000)K" }
    let millions = Double(tokens) / 1_000_000
    return millions < 10 && millions != millions.rounded()
      ? String(format: "%.1fM", millions) : "\(Int(millions.rounded()))M"
  }

  static func usageHelp(_ snapshot: ProviderUsageSnapshot) -> String {
    var lines: [String] = []
    for window in [snapshot.primary, snapshot.secondary, snapshot.modelSpecific].compactMap({ $0 })
    {
      var line = "\(window.label): \(Int(window.remainingPercent.rounded()))% remaining"
      if let reset = window.resetsAt {
        line += ", resets \(reset.formatted(date: .abbreviated, time: .shortened))"
      }
      lines.append(line)
    }
    if snapshot.availability == .stale {
      lines.append("Last update is stale: \(snapshot.message ?? "refresh failed")")
    } else {
      lines.append("Updated \(snapshot.fetchedAt.formatted(date: .omitted, time: .shortened))")
    }
    return lines.joined(separator: "\n")
  }
}

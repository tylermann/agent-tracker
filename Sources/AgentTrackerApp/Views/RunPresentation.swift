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
    case .needsAttention: .orange
    case .waiting: .green
    case .ended: .secondary
    case .unavailable: .red
    }
  }

  static func rowBackground(_ run: TrackedRun, isSelected: Bool) -> Color {
    if isSelected { return Color.accentColor.opacity(0.16) }
    switch run.status {
    case .needsAttention: return Color.orange.opacity(run.unreadAttention ? 0.14 : 0.1)
    case .waiting: return Color.green.opacity(0.08)
    case .working: return Color.blue.opacity(0.06)
    case .starting, .ended, .unavailable: return Color.primary.opacity(0.045)
    }
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

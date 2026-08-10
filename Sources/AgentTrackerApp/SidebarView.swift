import AgentTrackerCore
import SwiftUI

struct SidebarView: View {
  @ObservedObject var model: AgentTrackerModel
  @State private var recentExpanded = false

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      if model.runs.isEmpty {
        emptyState
      } else {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 14) {
            runSection("Needs You", runs: model.needsYou)
            runSection("Working", runs: model.working)
            runSection("Idle", runs: model.idle)
            if !model.recent.isEmpty {
              DisclosureGroup("Recent", isExpanded: $recentExpanded) {
                VStack(spacing: 6) {
                  ForEach(model.recent) { runRow($0) }
                }
                .padding(.top, 6)
              }
              .font(.headline)
            }
          }
          .padding(12)
        }
      }
      if model.usageMetersEnabled {
        Divider()
        usageMeters
      }
      if let error = model.errorMessage {
        Divider()
        Text(error)
          .font(.caption)
          .foregroundStyle(.red)
          .lineLimit(2)
          .padding(8)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .frame(minWidth: 280, idealWidth: 320, minHeight: 360)
    .background(.ultraThinMaterial)
  }

  private var usageMeters: some View {
    VStack(alignment: .leading, spacing: 7) {
      HStack {
        Text("Usage")
          .font(.caption.bold())
          .foregroundStyle(.secondary)
        Spacer()
        Button {
          model.refreshUsage()
        } label: {
          Image(systemName: "arrow.clockwise")
            .font(.caption2)
        }
        .buttonStyle(.plain)
        .help("Refresh usage")
      }
      ForEach(Harness.allCases, id: \.self) { harness in
        usageRow(harness, snapshot: model.usageSnapshots.first { $0.harness == harness })
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 9)
  }

  @ViewBuilder
  private func usageRow(_ harness: Harness, snapshot: ProviderUsageSnapshot?) -> some View {
    HStack(alignment: .top, spacing: 8) {
      Text(harness.displayName)
        .font(.caption)
        .frame(width: 42, alignment: .leading)
      if let snapshot {
        switch snapshot.availability {
        case .loggedOut, .error:
          Text(snapshot.message ?? "Unavailable")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
        case .ok, .stale:
          VStack(spacing: 4) {
            if let primary = snapshot.primary {
              usageLine(
                primary,
                overage: primary.usedPercent >= 100 ? snapshot.overage : nil,
                isStale: snapshot.availability == .stale
              )
            }
            if harness == .claude, let modelSpecific = snapshot.modelSpecific {
              usageLine(modelSpecific, isStale: snapshot.availability == .stale, compact: true)
            }
          }
          .help(usageHelp(snapshot))
        }
      } else {
        Text("Checking…")
          .font(.caption2)
          .foregroundStyle(.tertiary)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  }

  private func usageLine(
    _ window: UsageWindow,
    overage: UsageOverage? = nil,
    isStale: Bool,
    compact: Bool = false
  ) -> some View {
    let display = meterDisplay(window: window, overage: overage)
    return VStack(spacing: 2) {
      HStack(spacing: 4) {
        Text(display.label)
          .lineLimit(1)
        Spacer(minLength: 3)
        if isStale {
          Image(systemName: "clock.arrow.circlepath")
        }
        Text(display.value)
          .monospacedDigit()
      }
      .font(.caption2)
      .foregroundStyle(isStale ? .tertiary : .secondary)
      GeometryReader { geometry in
        ZStack(alignment: .leading) {
          Capsule().fill(Color.primary.opacity(0.09))
          Capsule()
            .fill(display.color)
            .frame(width: geometry.size.width * display.fraction)
        }
      }
      .frame(height: compact ? 3 : 4)
      .opacity(isStale ? 0.65 : 1)
    }
  }

  private struct MeterDisplay {
    var label: String
    var value: String
    var fraction: Double
    var color: Color
  }

  private func meterDisplay(window: UsageWindow, overage: UsageOverage?) -> MeterDisplay {
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

  private func usageHelp(_ snapshot: ProviderUsageSnapshot) -> String {
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

  private var header: some View {
    HStack {
      Label("Agents", systemImage: "person.2.fill")
        .font(.headline)
      Spacer()
      if model.unreadCount > 0 {
        Text("\(model.unreadCount)")
          .font(.caption.bold())
          .padding(.horizontal, 7)
          .padding(.vertical, 3)
          .background(.orange, in: Capsule())
          .foregroundStyle(.white)
      }
      Button {
        model.isDetached.toggle()
      } label: {
        Image(systemName: model.isDetached ? "arrow.down.left.and.arrow.up.right" : "pin.fill")
      }
      .buttonStyle(.plain)
      .help(model.isDetached ? "Attach to Ghostty" : "Detach panel")
    }
    .padding(12)
  }

  private var emptyState: some View {
    ContentUnavailableView {
      Label("No tracked agents", systemImage: "waveform.path.ecg")
    } description: {
      Text(
        "Install integrations in Settings, then start Claude, Codex, or Cursor from a new shell.")
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  @ViewBuilder
  private func runSection(_ title: String, runs: [TrackedRun]) -> some View {
    if !runs.isEmpty {
      VStack(alignment: .leading, spacing: 6) {
        Text(title).font(.headline)
        ForEach(runs) { runRow($0) }
      }
    }
  }

  private func runRow(_ run: TrackedRun) -> some View {
    Button {
      model.focus(run)
    } label: {
      HStack(alignment: .top, spacing: 9) {
        Circle()
          .fill(statusColor(run.status))
          .frame(width: 9, height: 9)
          .padding(.top, 5)
        VStack(alignment: .leading, spacing: 3) {
          HStack {
            Text(run.harness.displayName).font(.subheadline.bold())
            Text(run.status.displayName)
              .font(.caption)
              .foregroundStyle(.secondary)
            Spacer()
            if run.unreadAttention {
              Circle().fill(.orange).frame(width: 6, height: 6)
            }
          }
          Text(projectName(run))
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
          if let preview = run.promptPreview {
            Text(preview)
              .font(.caption)
              .foregroundStyle(.primary)
              .lineLimit(2)
          }
          HStack(spacing: 5) {
            if let branch = run.branch, !branch.isEmpty {
              Label(branch, systemImage: "arrow.triangle.branch")
            }
            Text(run.lastEventAt, style: .relative)
          }
          .font(.caption2)
          .foregroundStyle(.tertiary)
        }
      }
      .padding(9)
      .background(run.unreadAttention ? Color.orange.opacity(0.09) : Color.primary.opacity(0.045))
      .clipShape(RoundedRectangle(cornerRadius: 9))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  private func projectName(_ run: TrackedRun) -> String {
    let path = run.projectRoot ?? run.workingDirectory
    return path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Unknown project"
  }

  private func statusColor(_ status: RunStatus) -> Color {
    switch status {
    case .starting: .gray
    case .working: .blue
    case .needsAttention: .orange
    case .waiting: .green
    case .ended: .secondary
    case .unavailable: .red
    }
  }
}

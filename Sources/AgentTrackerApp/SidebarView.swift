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

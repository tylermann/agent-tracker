import AgentTrackerCore
import AppKit
import SwiftUI

struct SidebarView: View {
  @ObservedObject var model: AgentTrackerModel

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      if model.runs.isEmpty && model.recentTotalCount == 0 {
        emptyState
      } else {
        ScrollViewReader { proxy in
          ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
              runSection("Needs You", tint: .orange, runs: model.needsYou)
              runSection("Working", tint: .blue, runs: model.working)
              runSection("Idle", tint: .gray, runs: model.idle)
              if model.recentTotalCount > 0 {
                VStack(alignment: .leading, spacing: 6) {
                  Button {
                    model.recentExpanded.toggle()
                  } label: {
                    HStack(spacing: 6) {
                      Image(systemName: model.recentExpanded ? "chevron.down" : "chevron.right")
                        .font(SidebarTypography.caption.weight(.semibold))
                        .frame(width: 10)
                      sectionLabel("Recent", tint: .secondary, count: model.recentTotalCount)
                      Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                  }
                  .buttonStyle(.plain)
                  .accessibilityLabel("Recent")
                  .accessibilityValue(model.recentExpanded ? "Expanded" : "Collapsed")
                  .accessibilityHint("Shows or hides recent agent runs")

                  if model.recentExpanded {
                    VStack(spacing: 6) {
                      ForEach(model.recent) { runRow($0) }
                      if model.hasMoreRecent {
                        Button(
                          "Show \(min(AgentTrackerModel.recentPageSize, model.remainingRecentCount)) more"
                        ) {
                          model.showMoreRecent()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 2)
                        .accessibilityHint("Loads older recent agent runs")
                      }
                    }
                    .padding(.top, 6)
                  }
                }
              }
            }
            .padding(12)
          }
          .onChange(of: model.selectedRunID) { _, selected in
            guard let selected else { return }
            withAnimation(.easeOut(duration: 0.12)) {
              proxy.scrollTo(selected, anchor: .center)
            }
          }
        }
      }
      if model.usageMetersEnabled {
        Divider()
        usageMeters
      }
      if let error = model.errorMessage {
        Divider()
        Text(error)
          .font(SidebarTypography.caption)
          .foregroundStyle(.red)
          .lineLimit(2)
          .padding(8)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .frame(minWidth: 280, idealWidth: 320, minHeight: 360)
    // The transparent title bar reserves a large safe-area inset even though this panel does not
    // show window controls. Let the header use that space so it sits close to the panel's top edge.
    .ignoresSafeArea(.container, edges: .top)
    .background(.ultraThinMaterial)
  }

  private var usageMeters: some View {
    VStack(alignment: .leading, spacing: 7) {
      HStack {
        Text("Usage")
          .font(SidebarTypography.caption.weight(.bold))
          .foregroundStyle(.secondary)
        Spacer()
        Button {
          model.refreshUsage()
        } label: {
          Image(systemName: "arrow.clockwise")
            .font(SidebarTypography.caption2)
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
      providerLabel(harness, font: SidebarTypography.caption)
        .frame(width: 64, alignment: .leading)
      if let snapshot {
        switch snapshot.availability {
        case .loggedOut, .error:
          Text(snapshot.message ?? "Unavailable")
            .font(SidebarTypography.caption2)
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
          .help(RunPresentation.usageHelp(snapshot))
        }
      } else {
        Text("Checking…")
          .font(SidebarTypography.caption2)
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
    let display = RunPresentation.meterDisplay(window: window, overage: overage)
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
      .font(SidebarTypography.caption2)
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
      if let resetsAt = window.resetsAt {
        Text(RunPresentation.resetLabel(resetsAt))
          .font(SidebarTypography.resetLabel)
          .foregroundStyle(.tertiary)
          .lineLimit(1)
          .frame(maxWidth: .infinity, alignment: .trailing)
      }
    }
  }

  private var header: some View {
    HStack {
      Text("Agents")
        .font(SidebarTypography.headline)
      Spacer()
      if model.unreadCount > 0 {
        Text("\(model.unreadCount)")
          .font(SidebarTypography.caption.weight(.bold))
          .padding(.horizontal, 7)
          .padding(.vertical, 3)
          .background(.orange, in: Capsule())
          .foregroundStyle(.white)
      }
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
  private func runSection(_ title: String, tint: Color, runs: [TrackedRun]) -> some View {
    if !runs.isEmpty {
      VStack(alignment: .leading, spacing: 6) {
        sectionLabel(title, tint: tint, count: runs.count)
        ForEach(runs) { runRow($0) }
      }
    }
  }

  private func sectionLabel(_ title: String, tint: Color, count: Int) -> some View {
    HStack(spacing: 6) {
      Circle()
        .fill(tint)
        .frame(width: 7, height: 7)
      Text(title)
        .font(SidebarTypography.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .textCase(.uppercase)
      Text("\(count)")
        .font(SidebarTypography.caption2.monospacedDigit())
        .foregroundStyle(.tertiary)
    }
  }

  private func runRow(_ run: TrackedRun) -> some View {
    RunRow(model: model, run: run)
  }

  private func providerLabel(_ harness: Harness, font: Font) -> some View {
    ProviderLabel(harness: harness, font: font)
  }
}

private struct ProviderLabel: View {
  let harness: Harness
  let font: Font

  var body: some View {
    HStack(spacing: 5) {
      Image(nsImage: ProviderLogo.image(for: harness))
        .resizable()
        .interpolation(.high)
        .frame(width: 17, height: 17)
        .accessibilityHidden(true)
      Text(harness.displayName)
        .font(font)
    }
  }
}

private struct RunRow: View {
  @ObservedObject var model: AgentTrackerModel
  let run: TrackedRun

  /// How much of the opening prompt a row shows before and after the disclosure chevron is used.
  private static let collapsedLineLimit = 2
  /// Ten lines is enough to show the whole stored preview at the panel's usual width.
  private static let expandedLineLimit = 10

  /// Measured off hidden copies of the preview so the chevron only appears on rows whose prompt is
  /// actually cut off at the current panel width.
  @State private var fullPreviewHeight: CGFloat = 0
  @State private var clampedPreviewHeight: CGFloat = 0

  private var isSelected: Bool { model.selectedRunID == run.runID }
  private var isExpanded: Bool { model.isExpanded(run) }
  private var canExpand: Bool { fullPreviewHeight > clampedPreviewHeight + 0.5 }

  var body: some View {
    Button {
      model.focus(run)
    } label: {
      VStack(alignment: .leading, spacing: 3) {
        HStack {
          ProviderLabel(harness: run.harness, font: SidebarTypography.subheadline.weight(.bold))
          Text(run.status.displayName)
            .font(SidebarTypography.caption)
            .foregroundStyle(.secondary)
          Spacer()
          if run.status == .working {
            ProgressView()
              .controlSize(.small)
              .scaleEffect(0.55)
              .frame(width: 12, height: 12)
          }
          if run.unreadAttention {
            Circle().fill(.orange).frame(width: 6, height: 6)
          }
        }
        Text(RunPresentation.projectName(run))
          .font(SidebarTypography.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
        if let preview = run.promptPreview {
          previewText(preview)
            .lineLimit(isExpanded ? Self.expandedLineLimit : Self.collapsedLineLimit)
            .fixedSize(horizontal: false, vertical: true)
            .background(alignment: .topLeading) { previewMeasurements(preview) }
            .onPreferenceChange(FullPreviewHeightKey.self) { fullPreviewHeight = $0 }
            .onPreferenceChange(ClampedPreviewHeightKey.self) { clampedPreviewHeight = $0 }
        }
        HStack(spacing: 5) {
          if let branch = run.branch, !branch.isEmpty {
            Label(branch, systemImage: "arrow.triangle.branch")
          }
          Text(run.lastEventAt, style: .relative)
          // Leave room for the disclosure chevron overlaid on this corner of the row.
          if canExpand { Spacer(minLength: 22) }
        }
        .font(SidebarTypography.caption2)
        .foregroundStyle(.tertiary)
      }
      .padding(9)
      .padding(.leading, 5)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(RunPresentation.rowBackground(run, isSelected: isSelected))
      .overlay(alignment: .leading) {
        RunPresentation.statusColor(run.status).frame(width: 3)
      }
      .clipShape(RoundedRectangle(cornerRadius: 9))
      .overlay {
        RoundedRectangle(cornerRadius: 9)
          .strokeBorder(Color.accentColor, lineWidth: 2)
          .opacity(isSelected ? 1 : 0)
      }
      .contentShape(Rectangle())
      .opacity(run.status == .starting || run.status == .ended ? 0.75 : 1)
    }
    .buttonStyle(.plain)
    // Layered over the row button rather than nested inside its label, which would never receive
    // the click.
    .overlay(alignment: .bottomTrailing) {
      if canExpand { disclosure }
    }
    .id(run.runID)
  }

  private var disclosure: some View {
    Button {
      withAnimation(.easeOut(duration: 0.12)) { model.toggleExpanded(run) }
    } label: {
      Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
        .font(SidebarTypography.caption2.weight(.semibold))
        .foregroundStyle(.tertiary)
        .frame(width: 20, height: 18)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .padding(.trailing, 4)
    .padding(.bottom, 5)
    .help(isExpanded ? "Show less of the prompt" : "Show more of the prompt")
    .accessibilityLabel(isExpanded ? "Collapse prompt" : "Expand prompt")
  }

  private func previewText(_ preview: String) -> some View {
    Text(preview)
      .font(SidebarTypography.caption)
      .foregroundStyle(.primary)
      .multilineTextAlignment(.leading)
  }

  private func previewMeasurements(_ preview: String) -> some View {
    ZStack(alignment: .topLeading) {
      previewText(preview)
        .fixedSize(horizontal: false, vertical: true)
        .background(
          GeometryReader { geometry in
            Color.clear.preference(key: FullPreviewHeightKey.self, value: geometry.size.height)
          })
      previewText(preview)
        .lineLimit(Self.collapsedLineLimit)
        .fixedSize(horizontal: false, vertical: true)
        .background(
          GeometryReader { geometry in
            Color.clear.preference(key: ClampedPreviewHeightKey.self, value: geometry.size.height)
          })
    }
    .hidden()
    .accessibilityHidden(true)
  }
}

private struct FullPreviewHeightKey: PreferenceKey {
  static let defaultValue: CGFloat = 0
  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
    value = max(value, nextValue())
  }
}

private struct ClampedPreviewHeightKey: PreferenceKey {
  static let defaultValue: CGFloat = 0
  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
    value = max(value, nextValue())
  }
}

private enum SidebarTypography {
  /// Keep the panel compact while making its dense text one point easier to read.
  static let caption = Font.system(size: 12)
  static let caption2 = Font.system(size: 11)
  static let subheadline = Font.system(size: 12)
  static let headline = Font.system(size: 18, weight: .semibold)
  static let resetLabel = Font.system(size: 11)
}

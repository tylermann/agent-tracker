import AgentTrackerCore
import Charts
import SwiftUI

/// Stacked token-usage history bars behind the usage meters: one color family per provider
/// (Claude orange, Codex blue, Cursor purple), shaded per model.
struct TokenUsageChartView: View {
  @ObservedObject var model: AgentTrackerModel

  private static let shadeOpacities: [Double] = [1.0, 0.7, 0.5, 0.35]
  private static let otherOpacity = 0.25

  var body: some View {
    let data = TokenUsageChartData.build(
      rows: model.tokenUsageRows, granularity: model.usageHistoryGranularity)
    VStack(alignment: .leading, spacing: 6) {
      if data.isEmpty {
        Text("No usage recorded yet")
          .font(.system(size: 11))
          .foregroundStyle(.tertiary)
          .frame(maxWidth: .infinity, alignment: .center)
          .padding(.vertical, 12)
      } else {
        chart(data)
        legend(data)
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(accessibilitySummary(data))
  }

  private func chart(_ data: TokenUsageChartData) -> some View {
    Chart {
      ForEach(data.series) { series in
        ForEach(Array(series.values.enumerated()), id: \.offset) { index, value in
          if value > 0 {
            BarMark(
              x: .value("Bucket", data.buckets[index].label),
              y: .value("Tokens", value)
            )
            .foregroundStyle(by: .value("Series", series.id))
          }
        }
      }
    }
    .chartXScale(domain: data.buckets.map(\.label))
    .chartForegroundStyleScale(
      domain: data.series.map(\.id),
      range: data.series.map { color(for: $0) }
    )
    .chartLegend(.hidden)
    .chartXAxis {
      AxisMarks(values: xAxisLabels(data)) { _ in
        AxisValueLabel()
          .font(.system(size: 9))
      }
    }
    .chartYAxis {
      AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
        AxisGridLine()
        AxisValueLabel {
          if let tokens = value.as(Int.self) {
            Text(RunPresentation.tokenLabel(tokens))
              .font(.system(size: 9))
          }
        }
      }
    }
    .frame(height: 110)
  }

  /// 14 day labels do not fit in a 280-point panel, so day mode annotates every third bucket and
  /// week mode every second, always including the newest.
  private func xAxisLabels(_ data: TokenUsageChartData) -> [String] {
    let stride = model.usageHistoryGranularity == .day ? 3 : 2
    let last = data.buckets.count - 1
    return data.buckets.enumerated()
      .filter { (last - $0.offset) % stride == 0 }
      .map(\.element.label)
  }

  private func legend(_ data: TokenUsageChartData) -> some View {
    LazyVGrid(
      columns: [GridItem(.adaptive(minimum: 116), alignment: .leading)],
      alignment: .leading,
      spacing: 3
    ) {
      ForEach(data.series) { series in
        HStack(spacing: 4) {
          Circle()
            .fill(color(for: series))
            .frame(width: 6, height: 6)
          Text(legendLabel(series))
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .lineLimit(1)
          Text(RunPresentation.tokenLabel(series.total))
            .font(.system(size: 10))
            .foregroundStyle(.tertiary)
            .monospacedDigit()
        }
      }
    }
  }

  private func legendLabel(_ series: TokenUsageChartData.Series) -> String {
    if series.model == TokenUsageChartData.otherModelKey {
      return "\(series.harness.displayName) other"
    }
    return ModelIdentity.displayName(for: series.model) ?? series.harness.displayName
  }

  private func color(for series: TokenUsageChartData.Series) -> Color {
    let base: Color =
      switch series.harness {
      case .claude: .orange
      case .codex: .blue
      case .cursor: .purple
      }
    if series.model == TokenUsageChartData.otherModelKey {
      return base.opacity(Self.otherOpacity)
    }
    let index = min(series.shadeIndex, Self.shadeOpacities.count - 1)
    return base.opacity(Self.shadeOpacities[index])
  }

  private func accessibilitySummary(_ data: TokenUsageChartData) -> String {
    guard !data.isEmpty else { return "Token usage chart, no usage recorded yet" }
    let range =
      model.usageHistoryGranularity == .day
      ? "the last \(TokenUsageChartData.dayBucketCount) days"
      : "the last \(TokenUsageChartData.weekBucketCount) weeks"
    return "Token usage chart, \(RunPresentation.tokenLabel(data.totalFreshTokens)) "
      + "fresh tokens over \(range)"
  }
}

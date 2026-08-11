import Foundation

/// Keeps the last good snapshot per provider so a transient fetch failure degrades to stale data
/// instead of blanking the meter.
public enum UsageStalenessFilter {
  /// Passes fresh results through (recording them in `lastGood`); replaces a failed provider's
  /// result with its last good snapshot, marked stale and carrying the failure message. Providers
  /// that never succeeded keep their failure result.
  public static func merge(
    results: [ProviderUsageSnapshot],
    lastGood: inout [Harness: ProviderUsageSnapshot]
  ) -> [ProviderUsageSnapshot] {
    results.map { result in
      if result.availability == .ok {
        lastGood[result.harness] = result
        return result
      }
      guard var previous = lastGood[result.harness] else { return result }
      previous.availability = .stale
      previous.message = result.message
      return previous
    }
  }
}

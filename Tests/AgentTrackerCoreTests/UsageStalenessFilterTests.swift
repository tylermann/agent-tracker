import XCTest

@testable import AgentTrackerCore

final class UsageStalenessFilterTests: XCTestCase {
  private let fetchedAt = Date(timeIntervalSince1970: 1_700_000_000)

  private func snapshot(
    _ harness: Harness, availability: UsageAvailability, message: String? = nil
  ) -> ProviderUsageSnapshot {
    ProviderUsageSnapshot(
      harness: harness, availability: availability,
      primary: UsageWindow(label: "5h", usedPercent: 40),
      message: message, fetchedAt: fetchedAt)
  }

  func testGoodResultsPassThroughAndAreRecorded() {
    var lastGood: [Harness: ProviderUsageSnapshot] = [:]
    let fresh = snapshot(.claude, availability: .ok)
    let merged = UsageStalenessFilter.merge(results: [fresh], lastGood: &lastGood)
    XCTAssertEqual(merged, [fresh])
    XCTAssertEqual(lastGood[.claude], fresh)
  }

  func testFailureFallsBackToLastGoodMarkedStale() {
    var lastGood: [Harness: ProviderUsageSnapshot] = [:]
    let fresh = snapshot(.claude, availability: .ok)
    _ = UsageStalenessFilter.merge(results: [fresh], lastGood: &lastGood)

    let failure = ProviderUsageSnapshot(
      harness: .claude, availability: .error, message: "Offline", fetchedAt: fetchedAt)
    let merged = UsageStalenessFilter.merge(results: [failure], lastGood: &lastGood)

    XCTAssertEqual(merged.count, 1)
    XCTAssertEqual(merged[0].availability, .stale)
    XCTAssertEqual(merged[0].message, "Offline")
    XCTAssertEqual(merged[0].primary, fresh.primary)
    // The recorded good snapshot is untouched for the next round.
    XCTAssertEqual(lastGood[.claude]?.availability, .ok)
  }

  func testFailureWithoutHistoryIsReturnedAsIs() {
    var lastGood: [Harness: ProviderUsageSnapshot] = [:]
    let failure = ProviderUsageSnapshot(
      harness: .codex, availability: .loggedOut, message: "Not logged in", fetchedAt: fetchedAt)
    XCTAssertEqual(
      UsageStalenessFilter.merge(results: [failure], lastGood: &lastGood), [failure])
  }
}

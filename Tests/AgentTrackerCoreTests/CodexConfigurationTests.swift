import XCTest

@testable import AgentTrackerCore

final class CodexConfigurationTests: XCTestCase {
  func testDetectsAutomaticApprovalReviewer() {
    XCTAssertTrue(CodexConfiguration.usesAutomaticApprovalReview(
      configuration: "approvals_reviewer = \"auto_review\""))
  }

  func testDoesNotTreatManualReviewerAsAutomatic() {
    XCTAssertFalse(CodexConfiguration.usesAutomaticApprovalReview(
      configuration: "approvals_reviewer = \"manual\""))
  }
}

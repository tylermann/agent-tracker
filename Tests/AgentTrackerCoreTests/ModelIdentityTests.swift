import XCTest

@testable import AgentTrackerCore

final class ModelIdentityTests: XCTestCase {
  func testReadsCommonModelFlags() {
    XCTAssertEqual(
      ModelIdentity.commandLineModel(arguments: ["--model", "gpt-5.6-sol"]),
      "gpt-5.6-sol"
    )
    XCTAssertEqual(
      ModelIdentity.commandLineModel(arguments: ["--model=grok-4.6"]),
      "grok-4.6"
    )
    XCTAssertEqual(
      ModelIdentity.commandLineModel(arguments: ["-m", "fable"]),
      "fable"
    )
    XCTAssertEqual(
      ModelIdentity.commandLineModel(arguments: ["-c", "model=\"gpt-5.6-terra\""]),
      "gpt-5.6-terra"
    )
    XCTAssertEqual(
      ModelIdentity.commandLineModel(
        arguments: ["--model", "gpt-5.6-sol", "--model", "gpt-5.6-luna"]),
      "gpt-5.6-luna"
    )
  }

  func testMissingOrDefaultModelFallsBackToProvider() {
    XCTAssertNil(ModelIdentity.commandLineModel(arguments: ["--quiet"]))
    XCTAssertNil(ModelIdentity.commandLineModel(arguments: ["--model", "default"]))
    XCTAssertNil(ModelIdentity.displayName(for: nil))
    XCTAssertNil(ModelIdentity.displayName(for: "default"))
  }

  func testFormatsFriendlyRowLabels() {
    XCTAssertEqual(ModelIdentity.displayName(for: "grok-4.6"), "Grok 4.6")
    XCTAssertEqual(ModelIdentity.displayName(for: "claude-fable-5-20260801"), "Fable")
    XCTAssertEqual(ModelIdentity.displayName(for: "gpt-5.6-sol"), "Sol 5.6")
    XCTAssertEqual(ModelIdentity.displayName(for: "gpt-5.6-terra"), "Terra 5.6")
    XCTAssertEqual(ModelIdentity.displayName(for: "gpt-5.6-luna"), "Luna 5.6")
    XCTAssertEqual(ModelIdentity.displayName(for: "Gemini 3"), "Gemini 3")
  }
}

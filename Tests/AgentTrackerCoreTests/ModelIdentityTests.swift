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
    XCTAssertEqual(ModelIdentity.displayName(for: "claude-fable-5-20260801"), "Fable 5")
    XCTAssertEqual(ModelIdentity.displayName(for: "gpt-5.6-sol"), "Sol 5.6")
    XCTAssertEqual(ModelIdentity.displayName(for: "gpt-5.6-terra"), "Terra 5.6")
    XCTAssertEqual(ModelIdentity.displayName(for: "gpt-5.6-luna"), "Luna 5.6")
    XCTAssertEqual(ModelIdentity.displayName(for: "Gemini 3"), "Gemini 3")
  }

  func testKeepsAnthropicVersionsWithoutReleaseDates() {
    XCTAssertEqual(ModelIdentity.displayName(for: "claude-opus-5"), "Opus 5")
    XCTAssertEqual(ModelIdentity.displayName(for: "claude-opus-4-5-20251101"), "Opus 4.5")
    XCTAssertEqual(ModelIdentity.displayName(for: "claude-opus-4-1-20250805"), "Opus 4.1")
    XCTAssertEqual(ModelIdentity.displayName(for: "claude-haiku-4-5-20251001"), "Haiku 4.5")
    XCTAssertEqual(ModelIdentity.displayName(for: "claude-3-5-sonnet-20241022"), "Sonnet 3.5")
    XCTAssertEqual(ModelIdentity.displayName(for: "claude-3-opus-20240229"), "Opus 3")
    XCTAssertEqual(
      ModelIdentity.displayName(for: "claude-opus-5[context=1m,effort=high]"), "Opus 5")
    XCTAssertEqual(ModelIdentity.displayName(for: "us.anthropic.claude-opus-4-5-v1:0"), "Opus 4.5")
  }

  /// Settings-file aliases carry no version, so the family alone is the honest answer.
  func testBareAliasKeepsFamilyOnly() {
    XCTAssertEqual(ModelIdentity.displayName(for: "opus"), "Opus")
    XCTAssertEqual(ModelIdentity.displayName(for: "sonnet"), "Sonnet")
  }
}

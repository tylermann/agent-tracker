import XCTest

@testable import AgentTrackerCore

final class ProcessLauncherTests: XCTestCase {
  func testReturnsChildExitCode() throws {
    let pid = try ForegroundProcessLauncher.spawn(
      executable: "/bin/sh", arguments: ["-c", "exit 7"], environment: [:])
    XCTAssertEqual(try ForegroundProcessLauncher.wait(for: pid), 7)
  }

  func testSignalDeathIsReportedAs128PlusSignal() throws {
    let pid = try ForegroundProcessLauncher.spawn(
      executable: "/bin/sh", arguments: ["-c", "kill -TERM $$"], environment: [:])
    XCTAssertEqual(try ForegroundProcessLauncher.wait(for: pid), 128 + SIGTERM)
  }

  func testEnvironmentIsPassedToChild() throws {
    let output = FileManager.default.temporaryDirectory
      .appendingPathComponent("launcher-\(UUID().uuidString).txt")
    defer { try? FileManager.default.removeItem(at: output) }

    let pid = try ForegroundProcessLauncher.spawn(
      executable: "/bin/sh",
      arguments: ["-c", "printf %s \"$AGENT_TRACKER_TEST_VALUE\" > \"$OUTPUT_FILE\""],
      environment: [
        "AGENT_TRACKER_TEST_VALUE": "hello",
        "OUTPUT_FILE": output.path,
      ])
    XCTAssertEqual(try ForegroundProcessLauncher.wait(for: pid), 0)
    XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), "hello")
  }

  func testMissingExecutableThrows() {
    XCTAssertThrowsError(
      try ForegroundProcessLauncher.spawn(
        executable: "/nonexistent/binary", arguments: [], environment: [:]))
  }
}

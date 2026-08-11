import XCTest

@testable import AgentTrackerCore

final class IntegrationManagerTests: XCTestCase {
  private var home: URL!

  override func setUpWithError() throws {
    home = FileManager.default.temporaryDirectory
      .appendingPathComponent("AgentTrackerHome-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
    try Data(
      #"{"model":"opus","hooks":{"Stop":[{"matcher":"","hooks":[{"type":"command","command":"existing-hook"}]}]}}"#
        .utf8
    )
    .write(to: home.appendingPathComponent(".claude/settings.json"))
    try FileManager.default.createDirectory(
      at: home.appendingPathComponent(".codex"), withIntermediateDirectories: true)
    try Data("notify = [\"existing\"]\n".utf8).write(
      to: home.appendingPathComponent(".codex/config.toml"))
    try Data(
      #"{"hooks":{"PreToolUse":[{"matcher":"request_user_input","hooks":[{"type":"command","command":"old-helper event --source agent-tracker --harness codex --event PreToolUse"}]}]}}"#
        .utf8
    )
    .write(to: home.appendingPathComponent(".codex/hooks.json"))
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: home)
  }

  private func makeManager() -> IntegrationManager {
    // A stubbed resolver keeps these tests off the real login shell (`zsh -lic`), which is slow
    // and machine-dependent.
    IntegrationManager(home: home, executableResolver: { "/usr/local/bin/\($0.rawValue)" })
  }

  func testInstallIsIdempotentAndPreservesExistingConfiguration() throws {
    let manager = makeManager()
    _ = try manager.install(
      helperPath: "/Applications/Agent Tracker.app/Contents/MacOS/agent-tracker")
    _ = try manager.install(
      helperPath: "/Applications/Agent Tracker.app/Contents/MacOS/agent-tracker")

    let settings = try json(home.appendingPathComponent(".claude/settings.json"))
    XCTAssertEqual(settings["model"] as? String, "opus")
    let hooks = try XCTUnwrap(settings["hooks"] as? [String: Any])
    let stop = try XCTUnwrap(hooks["Stop"] as? [[String: Any]])
    XCTAssertEqual(stop.count, 2)

    let codexConfig = try String(
      contentsOf: home.appendingPathComponent(".codex/config.toml"), encoding: .utf8)
    XCTAssertEqual(codexConfig, "notify = [\"existing\"]\n")
    let codexHooksRoot = try json(home.appendingPathComponent(".codex/hooks.json"))
    let codexHooks = try XCTUnwrap(codexHooksRoot["hooks"] as? [String: Any])
    let preToolUse = try XCTUnwrap(codexHooks["PreToolUse"] as? [[String: Any]])
    XCTAssertEqual(preToolUse.count, 1)
    XCTAssertEqual(preToolUse.first?["matcher"] as? String, "")
    XCTAssertFalse(String(describing: preToolUse).contains("old-helper"))

    let cursorHooksRoot = try json(home.appendingPathComponent(".cursor/hooks.json"))
    let cursorHooks = try XCTUnwrap(cursorHooksRoot["hooks"] as? [String: Any])
    for event in [
      "preToolUse", "postToolUse", "beforeShellExecution", "afterShellExecution",
      "beforeMCPExecution", "afterMCPExecution",
    ] {
      XCTAssertEqual((cursorHooks[event] as? [[String: Any]])?.count, 1)
    }
    let zshrc = try String(contentsOf: home.appendingPathComponent(".zshrc"), encoding: .utf8)
    XCTAssertEqual(zshrc.components(separatedBy: "# >>> agent-tracker >>>").count - 1, 1)
  }

  func testUninstallRemovesOnlyOwnedEntries() throws {
    let manager = makeManager()
    _ = try manager.install(
      helperPath: "/Applications/Agent Tracker.app/Contents/MacOS/agent-tracker")
    _ = try manager.uninstall()

    let settings = try json(home.appendingPathComponent(".claude/settings.json"))
    let hooks = try XCTUnwrap(settings["hooks"] as? [String: Any])
    let stop = try XCTUnwrap(hooks["Stop"] as? [[String: Any]])
    XCTAssertEqual(stop.count, 1)
    XCTAssertTrue(String(describing: stop).contains("existing-hook"))
    let zshrc = try String(contentsOf: home.appendingPathComponent(".zshrc"), encoding: .utf8)
    XCTAssertFalse(zshrc.contains("agent-tracker"))
  }

  private func json(_ url: URL) throws -> [String: Any] {
    try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] ?? [:]
  }
}

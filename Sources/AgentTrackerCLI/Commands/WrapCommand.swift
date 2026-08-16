import AgentTrackerCore
import Darwin
import Foundation

/// Wraps a provider executable: records process start/exit events around it while keeping the
/// child interactive in this terminal.
enum WrapCommand: Command {
  static let name = "wrap"
  static let synopsis = "wrap --harness <claude|codex|cursor> -- <executable> [args...]"

  static func run(_ arguments: ArgumentScanner) throws {
    guard let harnessValue = arguments.option("--harness"),
      let harness = Harness(rawValue: harnessValue)
    else { throw CLIError.missing("--harness") }
    guard let childArguments = arguments.argumentsAfterSeparator() else {
      throw CLIError.missing("-- <executable> [arguments]")
    }
    let executable = childArguments[0]
    let modelID = ModelIdentity.commandLineModel(arguments: Array(childArguments.dropFirst()))
    let runID = UUID().uuidString
    let terminalID = try GhosttyAutomation.focusedTerminalID()
    let cwd = FileManager.default.currentDirectoryPath
    let wrapperPID = getpid()
    let inbox = try EventInbox()

    AppLauncher.launchIfAvailable()

    var environment = ProcessInfo.processInfo.environment
    environment["AGENT_TRACKER_RUN_ID"] = runID
    environment["AGENT_TRACKER_TERMINAL_ID"] = terminalID
    environment["AGENT_TRACKER_HARNESS"] = harness.rawValue
    environment["AGENT_TRACKER_CHILD_PID"] = String(wrapperPID)
    if let modelID { environment["AGENT_TRACKER_MODEL_ID"] = modelID }

    // The child must join this wrapper's foreground process group (see
    // ForegroundProcessLauncher); the wrapper itself then ignores the terminal's interrupt
    // signals and lets the child handle them.
    signal(SIGINT, SIG_IGN)
    signal(SIGQUIT, SIG_IGN)
    let childPID = try ForegroundProcessLauncher.spawn(
      executable: executable,
      arguments: Array(childArguments.dropFirst()),
      environment: environment
    )
    try inbox.enqueue(
      AgentEvent(
        runID: runID,
        harness: harness,
        kind: .processStarted,
        ghosttyTerminalID: terminalID,
        processID: wrapperPID,
        cwd: cwd,
        executable: executable,
        modelID: modelID
      ))
    let status = try ForegroundProcessLauncher.wait(for: childPID)
    try? inbox.enqueue(
      AgentEvent(
        runID: runID,
        harness: harness,
        kind: .processExited,
        ghosttyTerminalID: terminalID,
        processID: wrapperPID,
        cwd: cwd,
        executable: executable,
        modelID: modelID,
        exitCode: status
      ))
    exit(status)
  }
}

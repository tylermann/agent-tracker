import AgentTrackerCore
import Darwin
import Foundation

@main
enum AgentTrackerCLI {
  static func main() {
    do {
      try run()
    } catch {
      FileHandle.standardError.write(Data("agent-tracker: \(error.localizedDescription)\n".utf8))
      exit(1)
    }
  }

  private static func run() throws {
    var arguments = Array(CommandLine.arguments.dropFirst())
    guard let command = arguments.first else {
      printUsage()
      return
    }
    arguments.removeFirst()
    switch command {
    case "wrap":
      try wrap(arguments)
    case "event":
      try receiveEvent(arguments)
    case "install-integrations":
      let report = try IntegrationManager().install(helperPath: executablePath())
      print(report.text)
    case "uninstall-integrations":
      let report = try IntegrationManager().uninstall()
      print(report.text)
    case "doctor":
      let report = IntegrationManager().doctor(helperPath: executablePath())
      print(report.text)
      if !report.success { exit(2) }
    case "focus":
      guard let terminalID = arguments.first else { throw CLIError.missing("terminal id") }
      try GhosttyAutomation.focus(terminalID: terminalID)
    case "help", "--help", "-h":
      printUsage()
    default:
      throw CLIError.unknownCommand(command)
    }
  }

  private static func receiveEvent(_ arguments: [String]) throws {
    guard let harnessValue = option("--harness", in: arguments),
      let harness = Harness(rawValue: harnessValue)
    else { throw CLIError.missing("--harness") }
    guard let eventName = option("--event", in: arguments) else {
      throw CLIError.missing("--event")
    }
    let payload = FileHandle.standardInput.readDataToEndOfFile()
    let environment = GhosttyTerminalBinding.environmentByCapturingFocusedTerminal(
      for: eventName,
      environment: ProcessInfo.processInfo.environment
    )
    if let event = try EventMapper.map(
      harness: harness,
      eventName: eventName,
      payloadData: payload,
      environment: environment
    )
    {
      try EventInbox().enqueue(event)
    }
    // Codex Stop-family hooks require valid JSON on stdout. An empty object is a no-op.
    if harness == .codex && eventName.lowercased().contains("stop") {
      print("{}")
    }
  }

  private static func wrap(_ arguments: [String]) throws -> Never {
    guard let harnessValue = option("--harness", in: arguments),
      let harness = Harness(rawValue: harnessValue)
    else { throw CLIError.missing("--harness") }
    guard let separator = arguments.firstIndex(of: "--"), separator + 1 < arguments.count else {
      throw CLIError.missing("-- <executable> [arguments]")
    }
    let childArguments = Array(arguments[(separator + 1)...])
    let executable = childArguments[0]
    let runID = UUID().uuidString
    let terminalID = try GhosttyAutomation.focusedTerminalID()
    let cwd = FileManager.default.currentDirectoryPath
    let wrapperPID = getpid()
    let inbox = try EventInbox()

    launchAppIfAvailable()

    var environment = ProcessInfo.processInfo.environment
    environment["AGENT_TRACKER_RUN_ID"] = runID
    environment["AGENT_TRACKER_TERMINAL_ID"] = terminalID
    environment["AGENT_TRACKER_HARNESS"] = harness.rawValue
    environment["AGENT_TRACKER_CHILD_PID"] = String(wrapperPID)

    let child = Process()
    child.executableURL = URL(fileURLWithPath: executable)
    child.arguments = Array(childArguments.dropFirst())
    child.environment = environment
    child.currentDirectoryURL = URL(fileURLWithPath: cwd)
    child.standardInput = FileHandle.standardInput
    child.standardOutput = FileHandle.standardOutput
    child.standardError = FileHandle.standardError

    try child.run()
    // The child was spawned with the terminal's process group and receives terminal-generated
    // interrupts directly. Keep the wrapper alive long enough to persist its exit event.
    signal(SIGINT, SIG_IGN)
    signal(SIGQUIT, SIG_IGN)
    try inbox.enqueue(
      AgentEvent(
        runID: runID,
        harness: harness,
        kind: .processStarted,
        ghosttyTerminalID: terminalID,
        processID: wrapperPID,
        cwd: cwd,
        executable: executable
      ))
    child.waitUntilExit()
    let status: Int32 =
      child.terminationReason == .uncaughtSignal
      ? 128 + child.terminationStatus
      : child.terminationStatus
    try? inbox.enqueue(
      AgentEvent(
        runID: runID,
        harness: harness,
        kind: .processExited,
        ghosttyTerminalID: terminalID,
        processID: wrapperPID,
        cwd: cwd,
        executable: executable,
        exitCode: status
      ))
    exit(status)
  }

  private static func launchAppIfAvailable() {
    let helperURL = URL(fileURLWithPath: executablePath()).standardizedFileURL
    let contentsURL = helperURL.deletingLastPathComponent().deletingLastPathComponent()
    guard contentsURL.lastPathComponent == "Contents" else { return }
    let appURL = contentsURL.deletingLastPathComponent()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = ["-gj", appURL.path]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try? process.run()
  }

  private static func option(_ name: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else {
      return nil
    }
    return arguments[index + 1]
  }

  private static func executablePath() -> String {
    URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path
  }

  private static func printUsage() {
    print(
      """
      Agent Tracker CLI

        agent-tracker wrap --harness <claude|codex|cursor> -- <executable> [args...]
        agent-tracker event --harness <name> --event <hook-name>
        agent-tracker install-integrations
        agent-tracker uninstall-integrations
        agent-tracker doctor
        agent-tracker focus <ghostty-terminal-id>
      """)
  }
}

private enum CLIError: LocalizedError {
  case missing(String)
  case unknownCommand(String)

  var errorDescription: String? {
    switch self {
    case .missing(let value): "Missing \(value)."
    case .unknownCommand(let command): "Unknown command: \(command)"
    }
  }
}

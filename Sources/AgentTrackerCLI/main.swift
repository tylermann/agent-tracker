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
    var environment = GhosttyTerminalBinding.environmentByCapturingFocusedTerminal(
      for: eventName,
      environment: ProcessInfo.processInfo.environment
    )
    if harness == .codex, CodexConfiguration.usesAutomaticApprovalReview(environment: environment) {
      environment["AGENT_TRACKER_CODEX_AUTO_REVIEW"] = "1"
    }
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

    // Foundation's Process creates a separate process group on macOS. An interactive child in
    // that group is backgrounded relative to this wrapper, so its first terminal read receives
    // SIGTTIN and it appears to hang. Spawn it in this foreground process group instead.
    signal(SIGINT, SIG_IGN)
    signal(SIGQUIT, SIG_IGN)
    let childPID = try spawnForegroundChild(
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
        executable: executable
      ))
    let status = try waitForChild(childPID)
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

  private static func spawnForegroundChild(
    executable: String,
    arguments: [String],
    environment: [String: String]
  ) throws -> pid_t {
    var attributes: posix_spawnattr_t? = nil
    guard posix_spawnattr_init(&attributes) == 0 else {
      throw POSIXError(.EINVAL)
    }
    defer { posix_spawnattr_destroy(&attributes) }

    var signals = sigset_t()
    sigemptyset(&signals)
    sigaddset(&signals, SIGINT)
    sigaddset(&signals, SIGQUIT)
    guard posix_spawnattr_setsigdefault(&attributes, &signals) == 0,
      posix_spawnattr_setpgroup(&attributes, getpgrp()) == 0
    else { throw POSIXError(.EINVAL) }

    let flags = Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF)
    guard posix_spawnattr_setflags(&attributes, flags) == 0 else {
      throw POSIXError(.EINVAL)
    }

    var childPID: pid_t = 0
    let environmentEntries = environment.map { "\($0.key)=\($0.value)" }
    let result = withCStringArray([executable] + arguments) { argv in
      withCStringArray(environmentEntries) { envp in
        posix_spawn(&childPID, executable, nil, &attributes, argv, envp)
      }
    }
    guard result == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EINVAL)
    }
    return childPID
  }

  private static func waitForChild(_ pid: pid_t) throws -> Int32 {
    var waitStatus: Int32 = 0
    while waitpid(pid, &waitStatus, 0) == -1 {
      if errno == EINTR { continue }
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EINVAL)
    }
    let signal = waitStatus & 0x7f
    return signal == 0 ? (waitStatus >> 8) & 0xff : 128 + signal
  }

  private static func withCStringArray<Result>(
    _ strings: [String],
    _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) throws -> Result
  ) rethrows -> Result {
    var pointers = strings.map { strdup($0) }
    pointers.append(nil)
    defer {
      for pointer in pointers {
        if let pointer { free(pointer) }
      }
    }
    return try pointers.withUnsafeMutableBufferPointer { buffer in
      try body(buffer.baseAddress!)
    }
  }

  private static func launchAppIfAvailable() {
    var candidate = URL(fileURLWithPath: executablePath()).standardizedFileURL
      .deletingLastPathComponent()
    var appURL: URL?
    while candidate.path != "/" {
      if candidate.pathExtension == "app",
        Bundle(url: candidate)?.bundleIdentifier == "com.tyler.agenttracker"
      {
        appURL = candidate
        break
      }
      candidate.deleteLastPathComponent()
    }
    guard let appURL else { return }
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

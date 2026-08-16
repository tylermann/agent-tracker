import AgentTrackerCore
import Foundation

/// Receives one hook event on stdin (invoked by the provider's installed hook command) and drops
/// it into the inbox for the app to pick up.
enum EventCommand: Command {
  static let name = "event"
  static let synopsis = "event --harness <name> --event <hook-name>"

  static func run(_ arguments: ArgumentScanner) throws {
    guard let harnessValue = arguments.option("--harness"),
      let harness = Harness(rawValue: harnessValue)
    else { throw CLIError.missing("--harness") }
    guard let eventName = arguments.option("--event") else {
      throw CLIError.missing("--event")
    }
    let spec = ProviderRegistry.spec(for: harness)
    let payload = FileHandle.standardInput.readDataToEndOfFile()
    var environment = GhosttyTerminalBinding.environmentByCapturingFocusedTerminal(
      for: eventName,
      environment: ProcessInfo.processInfo.environment
    )
    environment = spec.enrichHookEnvironment(eventName, environment)
    if harness == .cursor, eventName.caseInsensitiveCompare("stop") == .orderedSame,
      let snapshot = try? CursorContextPayloadParser.stopHook(
        payload, environment: environment)
    {
      // Context telemetry must never make Cursor's lifecycle hook fail. The normal event below is
      // still delivered even if the optional fallback snapshot cannot be written.
      try? CursorContextSnapshotStore().write(snapshot)
    }
    if let event = try EventMapper.map(
      harness: harness,
      eventName: eventName,
      payloadData: payload,
      environment: environment
    ) {
      try EventInbox().enqueue(event)
    }
    // Some providers' Stop-family hooks require valid JSON on stdout. An empty object is a no-op.
    if spec.emitsJSONAckForStopEvents, eventName.lowercased().contains("stop") {
      print("{}")
    }
  }
}

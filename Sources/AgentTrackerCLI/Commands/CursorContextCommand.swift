import AgentTrackerCore
import Foundation

/// Receives Cursor Agent's custom status-line payload and records only its context-window totals.
/// It intentionally writes nothing to stdout so enabling the bridge does not add a visible line to
/// Cursor's prompt UI.
enum CursorContextCommand: Command {
  static let name = "cursor-context"
  static let synopsis = "cursor-context --source agent-tracker"

  static func run(_ arguments: ArgumentScanner) throws {
    let payload = FileHandle.standardInput.readDataToEndOfFile()
    guard
      let snapshot = try CursorContextPayloadParser.statusLine(
        payload, environment: ProcessInfo.processInfo.environment)
    else { return }
    try CursorContextSnapshotStore().write(snapshot)
  }
}

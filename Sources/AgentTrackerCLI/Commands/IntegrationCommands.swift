import AgentTrackerCore
import Foundation

enum InstallCommand: Command {
  static let name = "install-integrations"
  static let synopsis = "install-integrations"

  static func run(_ arguments: ArgumentScanner) throws {
    let report = try IntegrationManager().install(helperPath: CurrentExecutable.path())
    print(report.text)
  }
}

enum UninstallCommand: Command {
  static let name = "uninstall-integrations"
  static let synopsis = "uninstall-integrations"

  static func run(_ arguments: ArgumentScanner) throws {
    let report = try IntegrationManager().uninstall()
    print(report.text)
  }
}

enum DoctorCommand: Command {
  static let name = "doctor"
  static let synopsis = "doctor"

  static func run(_ arguments: ArgumentScanner) throws {
    let report = IntegrationManager().doctor(helperPath: CurrentExecutable.path())
    print(report.text)
    if !report.success { exit(2) }
  }
}

enum FocusCommand: Command {
  static let name = "focus"
  static let synopsis = "focus <ghostty-terminal-id>"

  static func run(_ arguments: ArgumentScanner) throws {
    guard let terminalID = arguments.first else { throw CLIError.missing("terminal id") }
    try GhosttyAutomation.focus(terminalID: terminalID)
  }
}

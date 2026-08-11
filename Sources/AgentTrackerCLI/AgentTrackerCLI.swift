import Foundation

@main
enum AgentTrackerCLI {
  /// Order here is the order commands appear in the usage text. Computed because a stored
  /// `[any Command.Type]` global trips strict-concurrency checking even though it is immutable.
  static var commands: [any Command.Type] {
    [
      WrapCommand.self,
      EventCommand.self,
      InstallCommand.self,
      UninstallCommand.self,
      DoctorCommand.self,
      FocusCommand.self,
    ]
  }

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
    guard let commandName = arguments.first else {
      printUsage()
      return
    }
    arguments.removeFirst()
    if ["help", "--help", "-h"].contains(commandName) {
      printUsage()
      return
    }
    guard let command = commands.first(where: { $0.name == commandName }) else {
      throw CLIError.unknownCommand(commandName)
    }
    try command.run(ArgumentScanner(arguments: arguments))
  }

  private static func printUsage() {
    let lines = ["Agent Tracker CLI", ""] + commands.map { "  agent-tracker \($0.synopsis)" }
    print(lines.joined(separator: "\n"))
  }
}

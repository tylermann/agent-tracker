import Foundation

/// One CLI subcommand. The dispatch table in main.swift and the usage text are both generated
/// from the conforming types, so they cannot drift from each other.
protocol Command {
  /// The subcommand word the user types.
  static var name: String { get }
  /// The usage line shown by `agent-tracker help`, starting with the subcommand word.
  static var synopsis: String { get }
  static func run(_ arguments: ArgumentScanner) throws
}

/// Minimal positional/flag scanning over the arguments after the subcommand word.
struct ArgumentScanner {
  let arguments: [String]

  var first: String? { arguments.first }

  /// The value following `name`, if present.
  func option(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else {
      return nil
    }
    return arguments[index + 1]
  }

  /// Everything after the first `--`, or nil when absent or empty.
  func argumentsAfterSeparator() -> [String]? {
    guard let separator = arguments.firstIndex(of: "--"), separator + 1 < arguments.count else {
      return nil
    }
    return Array(arguments[(separator + 1)...])
  }
}

enum CLIError: LocalizedError {
  case missing(String)
  case unknownCommand(String)

  var errorDescription: String? {
    switch self {
    case .missing(let value): "Missing \(value)."
    case .unknownCommand(let command): "Unknown command: \(command)"
    }
  }
}

enum CurrentExecutable {
  static func path() -> String {
    URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path
  }
}

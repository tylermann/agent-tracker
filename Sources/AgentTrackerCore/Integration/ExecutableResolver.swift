import Foundation

/// Locates provider executables by asking a login+interactive zsh, so the user's own PATH setup
/// (Homebrew, nvm, custom rc files) applies.
enum ExecutableResolver {
  static func resolve(named name: String, fileManager: FileManager = .default) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
    process.arguments = ["-lic", "whence -p \(ShellQuoting.quote(name))"]
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    do {
      try process.run()
      process.waitUntilExit()
      let lines =
        String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
        .components(separatedBy: .newlines) ?? []
      return lines.reversed().first {
        $0.hasPrefix("/") && fileManager.isExecutableFile(atPath: $0)
      }
    } catch {
      return nil
    }
  }
}

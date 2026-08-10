import Foundation

public struct GitMetadata: Sendable {
  public var root: String?
  public var branch: String?

  public static func read(from directory: String?) -> GitMetadata {
    guard let directory, FileManager.default.fileExists(atPath: directory) else {
      return GitMetadata()
    }
    return GitMetadata(
      root: git(["-C", directory, "rev-parse", "--show-toplevel"]),
      branch: git(["-C", directory, "branch", "--show-current"])
    )
  }

  private static func git(_ arguments: [String]) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do {
      try process.run()
      process.waitUntilExit()
      guard process.terminationStatus == 0 else { return nil }
      let value = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
      return value?.isEmpty == false ? value : nil
    } catch {
      return nil
    }
  }
}

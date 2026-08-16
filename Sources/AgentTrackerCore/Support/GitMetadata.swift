import Foundation

public struct GitDiffstat: Codable, Sendable, Equatable {
  public var files: Int

  public init(files: Int) {
    self.files = files
  }

  public var hasChanges: Bool { files > 0 }
}

public struct GitMetadata: Sendable {
  public var root: String?
  public var branch: String?
  public var diffstat: GitDiffstat?

  public static func read(from directory: String?, includeDiffstat: Bool = false) -> GitMetadata {
    guard let directory, FileManager.default.fileExists(atPath: directory) else {
      return GitMetadata()
    }
    var metadata = GitMetadata(
      root: git(["-C", directory, "rev-parse", "--show-toplevel"]),
      branch: git(["-C", directory, "branch", "--show-current"])
    )
    if includeDiffstat, metadata.root != nil {
      metadata.diffstat = diffstat(from: directory)
    }
    return metadata
  }

  /// One count per dirty path in `git status --porcelain`, including untracked and deleted files.
  static func parsePorcelain(_ output: String) -> GitDiffstat {
    var files = 0
    for line in output.split(whereSeparator: \.isNewline) {
      guard line.count >= 2 else { continue }
      let staged = line[line.startIndex]
      let unstaged = line[line.index(after: line.startIndex)]
      if isDirtyFile(staged: staged, unstaged: unstaged) { files += 1 }
    }
    return GitDiffstat(files: files)
  }

  private static func diffstat(from directory: String) -> GitDiffstat {
    let porcelain =
      git([
        "-C", directory, "-c", "core.quotepath=false", "status", "--porcelain=v1", "-uall",
      ]) ?? ""
    return parsePorcelain(porcelain)
  }

  private static func isDirtyFile(staged: Character, unstaged: Character) -> Bool {
    // Staged add that was then deleted from the working tree never became a real file.
    if staged == "A", unstaged == "D" { return false }
    if staged == " ", unstaged == " " { return false }
    return true
  }

  private static func git(_ arguments: [String]) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    // Read-only lookups must not block an agent that currently holds the index lock.
    process.arguments = ["--no-optional-locks"] + arguments
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

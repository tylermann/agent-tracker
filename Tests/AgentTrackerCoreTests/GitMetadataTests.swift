import XCTest

@testable import AgentTrackerCore

final class GitMetadataTests: XCTestCase {
  private var repository: URL!

  override func tearDownWithError() throws {
    if let repository {
      try? FileManager.default.removeItem(at: repository)
    }
    repository = nil
  }

  func testParsePorcelainCountsEachDirtyFileOnce() {
    XCTAssertEqual(
      GitMetadata.parsePorcelain(
        """
        M  tracked.swift
         M unstaged.swift
        A  added.swift
        ?? new.swift
        D  gone.swift
         D also-gone.swift
        R  old.swift -> renamed.swift
        AD vanished.swift
        """
      ),
      GitDiffstat(files: 7)
    )
    XCTAssertEqual(GitMetadata.parsePorcelain(""), GitDiffstat(files: 0))
  }

  func testReadWithoutDiffstatLeavesCountsUnset() throws {
    repository = try makeRepository()
    try append(to: "file.txt", text: "more\n")

    let metadata = GitMetadata.read(from: repository.path)
    XCTAssertEqual((metadata.root as NSString?)?.standardizingPath, repository.path)
    XCTAssertFalse((metadata.branch ?? "").isEmpty)
    XCTAssertNil(metadata.diffstat)
  }

  func testDiffstatCountsAModifiedFileOnce() throws {
    repository = try makeRepository()
    try append(to: "file.txt", text: "line two\nline three\n")

    let metadata = GitMetadata.read(from: repository.path, includeDiffstat: true)
    XCTAssertEqual(metadata.diffstat, GitDiffstat(files: 1))
  }

  func testDiffstatCountsEachUntrackedFile() throws {
    repository = try makeRepository()
    try write("new.swift", text: "one\ntwo\nthree\n")
    try write("other.swift", text: "x\n")

    let metadata = GitMetadata.read(from: repository.path, includeDiffstat: true)
    XCTAssertEqual(metadata.diffstat, GitDiffstat(files: 2))
  }

  func testDiffstatCountsDeletedFiles() throws {
    repository = try makeRepository()
    try FileManager.default.removeItem(at: repository.appendingPathComponent("file.txt"))

    let metadata = GitMetadata.read(from: repository.path, includeDiffstat: true)
    XCTAssertEqual(metadata.diffstat, GitDiffstat(files: 1))
  }

  func testCleanRepositoryHasEmptyDiffstat() throws {
    repository = try makeRepository()

    let metadata = GitMetadata.read(from: repository.path, includeDiffstat: true)
    XCTAssertEqual(metadata.diffstat, GitDiffstat(files: 0))
    XCTAssertFalse(metadata.diffstat?.hasChanges ?? true)
  }

  func testNonGitDirectoryIsEmpty() throws {
    repository = FileManager.default.temporaryDirectory
      .appendingPathComponent("AgentTrackerNotGit-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)

    let metadata = GitMetadata.read(from: repository.path, includeDiffstat: true)
    XCTAssertNil(metadata.root)
    XCTAssertNil(metadata.branch)
    XCTAssertNil(metadata.diffstat)
  }

  private func makeRepository() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("AgentTrackerGit-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    try git(["init"], in: url)
    try git(["config", "user.email", "test@example.com"], in: url)
    try git(["config", "user.name", "Test"], in: url)
    try write("file.txt", text: "hello\n", in: url)
    try git(["add", "file.txt"], in: url)
    try git(["commit", "-m", "init"], in: url)
    return url
  }

  private func write(_ name: String, text: String, in directory: URL? = nil) throws {
    try text.write(
      to: (directory ?? repository).appendingPathComponent(name), atomically: true, encoding: .utf8)
  }

  private func append(to name: String, text: String) throws {
    let url = repository.appendingPathComponent(name)
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(text.utf8))
  }

  private func git(_ arguments: [String], in directory: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-C", directory.path] + arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    XCTAssertEqual(process.terminationStatus, 0, "git \(arguments.joined(separator: " "))")
  }
}

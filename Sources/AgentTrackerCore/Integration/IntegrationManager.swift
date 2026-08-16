import Foundation

public struct IntegrationReport: Sendable {
  public var lines: [String]
  public var success: Bool

  public init(lines: [String] = [], success: Bool = true) {
    self.lines = lines
    self.success = success
  }

  public var text: String { lines.joined(separator: "\n") }
}

/// Orchestrates installing, removing, and diagnosing the shell wrappers and provider hooks that
/// feed events into Agent Tracker.
public final class IntegrationManager: @unchecked Sendable {
  private let home: URL
  private let fileManager: FileManager
  private let executableResolver: (@Sendable (Harness) -> String?)?
  private let shell: ShellIntegration
  private let hooks: HookConfigurator
  private let cursorStatusLine: CursorStatusLineConfigurator

  public init(
    home: URL = FileManager.default.homeDirectoryForCurrentUser,
    fileManager: FileManager = .default,
    executableResolver: (@Sendable (Harness) -> String?)? = nil
  ) {
    self.home = home
    self.fileManager = fileManager
    self.executableResolver = executableResolver
    shell = ShellIntegration(home: home, fileManager: fileManager)
    hooks = HookConfigurator(
      home: home, fileManager: fileManager, marker: "--source agent-tracker")
    cursorStatusLine = CursorStatusLineConfigurator(
      home: home, fileManager: fileManager, marker: "cursor-context --source agent-tracker")
  }

  public func install(helperPath: String) throws -> IntegrationReport {
    var report = IntegrationReport()
    let executables = resolveHarnessExecutables()
    let missing = Harness.allCases.filter { executables[$0] == nil }
    for harness in missing {
      report.lines.append(
        "Warning: could not locate \(harness.displayName); its wrapper was not installed.")
    }

    try shell.installWrappers(helperPath: helperPath, executables: executables)
    report.lines.append("Installed managed zsh wrappers.")
    for spec in ProviderRegistry.all {
      try hooks.merge(spec, helperPath: helperPath)
      report.lines.append(spec.hooks.installReportLine)
    }
    if try cursorStatusLine.install(helperPath: helperPath) == .skippedExisting {
      report.lines.append(
        "Warning: preserved the existing Cursor status line; context will update at turn end.")
    }
    report.lines.append("Open a new shell or run: source ~/.zshrc")
    return report
  }

  public func uninstall() throws -> IntegrationReport {
    var report = IntegrationReport()
    try shell.removeWrappers()
    report.lines.append("Removed managed zsh wrappers.")
    for spec in ProviderRegistry.all {
      try hooks.remove(spec)
      report.lines.append(spec.hooks.removeReportLine)
    }
    try cursorStatusLine.uninstall()
    return report
  }

  public func doctor(helperPath: String? = nil) -> IntegrationReport {
    var lines: [String] = []
    var success = true
    if FileManager.default.fileExists(atPath: "/Applications/Ghostty.app") {
      lines.append("✓ Ghostty is installed")
    } else {
      lines.append("✗ Ghostty was not found in /Applications")
      success = false
    }
    if let version = GhosttyAutomation.ghosttyVersion() {
      lines.append("✓ Ghostty AppleScript responded (\(version))")
    } else {
      lines.append("! Ghostty AppleScript is unavailable or permission has not been granted")
    }
    let executables = resolveHarnessExecutables()
    for harness in Harness.allCases {
      if let path = executables[harness] {
        lines.append("✓ \(harness.displayName): \(path)")
      } else {
        lines.append("✗ \(harness.displayName) executable not found")
        success = false
      }
    }
    if let helperPath {
      let exists = fileManager.isExecutableFile(atPath: helperPath)
      lines.append("\(exists ? "✓" : "✗") Helper: \(helperPath)")
      success = success && exists
    }
    let shellFile = home.appendingPathComponent(".config/agent-tracker/shell.zsh")
    lines.append("\(fileManager.fileExists(atPath: shellFile.path) ? "✓" : "!") Shell integration")
    lines.append("Data stays local in ~/Library/Application Support/AgentTracker")
    return IntegrationReport(lines: lines, success: success)
  }

  public func resolveHarnessExecutables() -> [Harness: String] {
    if let executableResolver {
      return Dictionary(
        uniqueKeysWithValues: Harness.allCases.compactMap { harness in
          executableResolver(harness).map { (harness, $0) }
        })
    }
    return Dictionary(
      uniqueKeysWithValues: ProviderRegistry.all.compactMap { spec in
        ExecutableResolver.resolve(named: spec.resolutionExecutableName, fileManager: fileManager)
          .map { (spec.harness, $0) }
      })
  }
}

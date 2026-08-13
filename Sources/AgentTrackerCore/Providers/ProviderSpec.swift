import Foundation

/// Everything Agent Tracker needs to know about one agent provider (harness): how to install its
/// hooks, wrap its executable, read its credentials, and fetch/parse its usage. Adding a provider
/// means adding a `Harness` case, one `<Name>Provider.swift` defining a spec, and a logo resource —
/// `ProviderRegistry.spec(for:)` is an exhaustive switch, so the compiler flags the rest.
public struct ProviderSpec: Sendable {
  public let harness: Harness
  /// The executable name resolved on the user's PATH (e.g. Cursor installs as `agent`).
  public let resolutionExecutableName: String
  /// Shell function names the managed zsh wrapper defines for this provider.
  public let wrapperFunctionNames: [String]
  public let hooks: HookInstallation
  public let usage: UsageSpec
  /// PNG resource name in the app bundle's provider logos.
  public let logoResourceName: String
  /// Adjusts the hook environment before an event is mapped (e.g. Codex marks automatic
  /// approval review). Identity for most providers.
  public let enrichHookEnvironment: @Sendable (String, [String: String]) -> [String: String]
  /// Whether Stop-family hooks must receive a JSON acknowledgment on stdout (Codex).
  public let emitsJSONAckForStopEvents: Bool

  public init(
    harness: Harness,
    resolutionExecutableName: String,
    wrapperFunctionNames: [String],
    hooks: HookInstallation,
    usage: UsageSpec,
    logoResourceName: String,
    enrichHookEnvironment: @escaping @Sendable (String, [String: String]) -> [String: String] =
      { _, environment in environment },
    emitsJSONAckForStopEvents: Bool = false
  ) {
    self.harness = harness
    self.resolutionExecutableName = resolutionExecutableName
    self.wrapperFunctionNames = wrapperFunctionNames
    self.hooks = hooks
    self.usage = usage
    self.logoResourceName = logoResourceName
    self.enrichHookEnvironment = enrichHookEnvironment
    self.emitsJSONAckForStopEvents = emitsJSONAckForStopEvents
  }
}

/// How a provider's lifecycle hooks are written into its configuration file.
public struct HookInstallation: Sendable {
  public enum Style: Sendable {
    /// Claude/Codex format: entries are `{matcher, hooks: [{type, command, timeout}]}` groups.
    case nestedMatcherGroups
    /// Cursor format: entries are flat `{command, timeout}` objects.
    case flatEntries
  }

  /// Config file path relative to the user's home directory.
  public let configPath: String
  /// Hook event names to register. Every name here must map to a sensible kind in EventMapper —
  /// ProviderParityTests enforces that.
  public let events: [String]
  public let style: Style
  /// Root-level keys ensured on the config file (e.g. Cursor's `"version": 1`).
  public let rootDefaults: [String: Int]
  /// Seconds Codex/Claude/Cursor wait for a hook command. Codex clamps `SessionEnd` at 3s.
  public let defaultTimeoutSeconds: Int
  /// Per-event overrides of `defaultTimeoutSeconds`.
  public let eventTimeouts: [String: Int]
  public let installReportLine: String
  public let removeReportLine: String

  public init(
    configPath: String,
    events: [String],
    style: Style,
    rootDefaults: [String: Int] = [:],
    defaultTimeoutSeconds: Int = 5,
    eventTimeouts: [String: Int] = [:],
    installReportLine: String,
    removeReportLine: String
  ) {
    self.configPath = configPath
    self.events = events
    self.style = style
    self.rootDefaults = rootDefaults
    self.defaultTimeoutSeconds = defaultTimeoutSeconds
    self.eventTimeouts = eventTimeouts
    self.installReportLine = installReportLine
    self.removeReportLine = removeReportLine
  }

  func timeoutSeconds(for event: String) -> Int {
    eventTimeouts[event] ?? defaultTimeoutSeconds
  }
}

/// How to read a provider's credential and fetch/parse its usage endpoint.
public struct UsageSpec: Sendable {
  /// (home directory, allowKeychainPrompt) → credential.
  public let readCredential: @Sendable (URL, Bool) throws -> UsageCredential
  public let request: @Sendable (UsageCredential) -> URLRequest
  /// (response body, fetchedAt) → snapshot.
  public let parse: @Sendable (Data, Date) throws -> ProviderUsageSnapshot

  public init(
    readCredential: @escaping @Sendable (URL, Bool) throws -> UsageCredential,
    request: @escaping @Sendable (UsageCredential) -> URLRequest,
    parse: @escaping @Sendable (Data, Date) throws -> ProviderUsageSnapshot
  ) {
    self.readCredential = readCredential
    self.request = request
    self.parse = parse
  }
}

public enum ProviderRegistry {
  /// All providers in `Harness.allCases` order — the install flow and UI rely on that ordering.
  public static let all: [ProviderSpec] = Harness.allCases.map(spec(for:))

  public static func spec(for harness: Harness) -> ProviderSpec {
    switch harness {
    case .claude: ClaudeProvider.spec
    case .codex: CodexProvider.spec
    case .cursor: CursorProvider.spec
    }
  }
}

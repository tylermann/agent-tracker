import AgentTrackerCore
import Foundation

enum UsageFetcher {
  private actor CredentialCache {
    private var credentials: [Harness: Result<UsageCredential, UsageCredentialError>] = [:]

    func credential(for spec: ProviderSpec, reload: Bool) throws -> UsageCredential {
      if !reload, let cached = credentials[spec.harness] {
        return try cached.get()
      }
      let result: Result<UsageCredential, UsageCredentialError>
      do {
        let credential = try spec.usage.readCredential(
          FileManager.default.homeDirectoryForCurrentUser, reload)
        result = .success(credential)
      } catch let error as UsageCredentialError {
        result = .failure(error)
      } catch {
        result = .failure(.unavailable(error.localizedDescription))
      }
      credentials[spec.harness] = result
      return try result.get()
    }

    func remove(_ harness: Harness) {
      credentials.removeValue(forKey: harness)
    }

    func removeAll() {
      credentials.removeAll()
    }
  }

  private static let credentialCache = CredentialCache()

  private enum FetchError: LocalizedError {
    case rejected(Int)
    case invalidResponse
    case unexpectedBody(String)

    var errorDescription: String? {
      switch self {
      case .rejected(let status): "Usage request failed (HTTP \(status))."
      case .invalidResponse: "The usage service returned an invalid response."
      case .unexpectedBody(let snippet): "Unexpected usage-events response: \(snippet)"
      }
    }
  }

  static func fetchAll(forceCredentialReload: Bool = false) async -> [ProviderUsageSnapshot] {
    await withTaskGroup(of: ProviderUsageSnapshot.self) { group in
      for spec in ProviderRegistry.all {
        group.addTask { await fetch(spec, forceCredentialReload: forceCredentialReload) }
      }
      var results: [ProviderUsageSnapshot] = []
      for await result in group { results.append(result) }
      return results.sorted { harnessIndex($0.harness) < harnessIndex($1.harness) }
    }
  }

  static func clearCredentialCache() async {
    await credentialCache.removeAll()
  }

  /// Fetches Cursor's per-request usage events for the token history chart, paging until the
  /// window is exhausted. Shares the meters' credential cache, so an auth failure in either path
  /// signs the provider out once for both.
  static func fetchCursorUsageEvents(startMs: Int64, endMs: Int64) async throws
    -> [CursorUsageEvent]
  {
    let spec = ProviderRegistry.spec(for: .cursor)
    do {
      let credential = try await credentialCache.credential(for: spec, reload: false)
      let pageSize = 200
      var events: [CursorUsageEvent] = []
      for page in 1...25 {
        let request = UsageRequestBuilder.cursorUsageEvents(
          credential: credential, startMs: startMs, endMs: endMs, page: page, pageSize: pageSize)
        let data = try await responseData(for: request)
        let parsed: (events: [CursorUsageEvent], totalCount: Int)
        do {
          parsed = try UsageResponseParser.cursorUsageEvents(data)
        } catch {
          // The endpoint is undocumented; when its shape changes, the local log needs to show
          // what actually came back, not just that parsing failed.
          throw FetchError.unexpectedBody(String(decoding: data.prefix(300), as: UTF8.self))
        }
        events.append(contentsOf: parsed.events)
        if parsed.events.count < pageSize || events.count >= parsed.totalCount { break }
      }
      return events
    } catch FetchError.rejected(let status) where status == 401 || status == 403 {
      await credentialCache.remove(.cursor)
      throw UsageCredentialError.loggedOut
    }
  }

  private static func fetch(
    _ spec: ProviderSpec, forceCredentialReload: Bool, didRetryAuth: Bool = false
  ) async -> ProviderUsageSnapshot {
    let harness = spec.harness
    do {
      let credential = try await credentialCache.credential(
        for: spec, reload: forceCredentialReload)
      let data = try await responseData(for: spec.usage.request(credential))
      return try spec.usage.parse(data, Date())
    } catch UsageCredentialError.loggedOut {
      return unavailable(harness, availability: .loggedOut, message: "Not logged in")
    } catch FetchError.rejected(let status) where status == 401 || status == 403 {
      await credentialCache.remove(harness)
      // The in-memory token (or leftover credentials file) is often one rotation behind
      // Claude Code's keychain item. Re-read once in this cycle so refresh is not a no-op.
      if !didRetryAuth {
        return await fetch(
          spec, forceCredentialReload: forceCredentialReload, didRetryAuth: true)
      }
      return unavailable(
        harness, availability: .loggedOut,
        message: "Sign in to \(harness.displayName) again")
    } catch {
      return unavailable(harness, message: concise(error))
    }
  }

  private static func responseData(for request: URLRequest) async throws -> Data {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 15
    configuration.timeoutIntervalForResource = 20
    let session = URLSession(configuration: configuration)
    let (data, response) = try await session.data(for: request)
    guard let response = response as? HTTPURLResponse else { throw FetchError.invalidResponse }
    guard (200..<300).contains(response.statusCode) else {
      throw FetchError.rejected(response.statusCode)
    }
    return data
  }

  private static func unavailable(
    _ harness: Harness,
    availability: UsageAvailability = .error,
    message: String
  ) -> ProviderUsageSnapshot {
    ProviderUsageSnapshot(harness: harness, availability: availability, message: message)
  }

  private static func concise(_ error: Error) -> String {
    if error is UsageParseError { return "Usage format changed" }
    if let error = error as? URLError {
      switch error.code {
      case .notConnectedToInternet, .networkConnectionLost: return "Offline"
      case .timedOut: return "Request timed out"
      default: return "Usage unavailable"
      }
    }
    return error.localizedDescription
  }

  private static func harnessIndex(_ harness: Harness) -> Int {
    Harness.allCases.firstIndex(of: harness) ?? .max
  }
}

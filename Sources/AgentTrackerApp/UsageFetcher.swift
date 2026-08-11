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

    var errorDescription: String? {
      switch self {
      case .rejected(let status): "Usage request failed (HTTP \(status))."
      case .invalidResponse: "The usage service returned an invalid response."
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

  private static func fetch(
    _ spec: ProviderSpec, forceCredentialReload: Bool
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

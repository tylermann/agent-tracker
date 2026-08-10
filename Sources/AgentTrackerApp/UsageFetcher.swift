import AgentTrackerCore
import Foundation

enum UsageFetcher {
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

  static func fetchAll() async -> [ProviderUsageSnapshot] {
    await withTaskGroup(of: ProviderUsageSnapshot.self) { group in
      group.addTask { await fetchClaude() }
      group.addTask { await fetchCodex() }
      group.addTask { await fetchCursor() }
      var results: [ProviderUsageSnapshot] = []
      for await result in group { results.append(result) }
      return results.sorted { harnessIndex($0.harness) < harnessIndex($1.harness) }
    }
  }

  private static func fetchClaude() async -> ProviderUsageSnapshot {
    do {
      let credential = try UsageCredentialReader.claude()
      var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
      request.timeoutInterval = 15
      request.cachePolicy = .reloadIgnoringLocalCacheData
      request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
      request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
      request.setValue("application/json", forHTTPHeaderField: "Accept")
      request.setValue("claude-code/agent-tracker", forHTTPHeaderField: "User-Agent")
      let data = try await responseData(for: request)
      return try UsageResponseParser.claude(data)
    } catch UsageCredentialError.loggedOut {
      return unavailable(.claude, availability: .loggedOut, message: "Not logged in")
    } catch FetchError.rejected(let status) where status == 401 || status == 403 {
      return unavailable(.claude, availability: .loggedOut, message: "Sign in to Claude again")
    } catch {
      return unavailable(.claude, message: concise(error))
    }
  }

  private static func fetchCodex() async -> ProviderUsageSnapshot {
    do {
      let credential = try UsageCredentialReader.codex()
      var request = URLRequest(
        url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
      request.timeoutInterval = 15
      request.cachePolicy = .reloadIgnoringLocalCacheData
      request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
      request.setValue("application/json", forHTTPHeaderField: "Accept")
      request.setValue("codex-cli", forHTTPHeaderField: "User-Agent")
      if let accountID = credential.accountID {
        request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
      }
      let data = try await responseData(for: request)
      return try UsageResponseParser.codex(data)
    } catch UsageCredentialError.loggedOut {
      return unavailable(.codex, availability: .loggedOut, message: "Not logged in")
    } catch FetchError.rejected(let status) where status == 401 || status == 403 {
      return unavailable(.codex, availability: .loggedOut, message: "Sign in to Codex again")
    } catch {
      return unavailable(.codex, message: concise(error))
    }
  }

  private static func fetchCursor() async -> ProviderUsageSnapshot {
    do {
      let credential = try UsageCredentialReader.cursor()
      var request = URLRequest(
        url: URL(
          string:
            "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage")!)
      request.httpMethod = "POST"
      request.httpBody = Data("{}".utf8)
      request.timeoutInterval = 15
      request.cachePolicy = .reloadIgnoringLocalCacheData
      request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.setValue("application/json", forHTTPHeaderField: "Accept")
      request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
      let data = try await responseData(for: request)
      return try UsageResponseParser.cursor(data)
    } catch UsageCredentialError.loggedOut {
      return unavailable(.cursor, availability: .loggedOut, message: "Not logged in")
    } catch FetchError.rejected(let status) where status == 401 || status == 403 {
      return unavailable(.cursor, availability: .loggedOut, message: "Sign in to Cursor again")
    } catch {
      return unavailable(.cursor, message: concise(error))
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

import Foundation

public enum UsageAvailability: String, Codable, Equatable, Sendable {
  case ok
  case loggedOut
  case error
  case stale
}

public struct UsageWindow: Codable, Equatable, Sendable {
  public var label: String
  public var usedPercent: Double
  public var resetsAt: Date?

  public init(label: String, usedPercent: Double, resetsAt: Date? = nil) {
    self.label = label
    self.usedPercent = min(max(usedPercent, 0), 100)
    self.resetsAt = resetsAt
  }

  public var remainingPercent: Double { max(0, 100 - usedPercent) }
}

public struct UsageOverage: Codable, Equatable, Sendable {
  public var isEnabled: Bool
  public var usedPercent: Double?
  public var usedAmount: Double?
  public var limitAmount: Double?
  public var unit: String?

  public init(
    isEnabled: Bool,
    usedPercent: Double? = nil,
    usedAmount: Double? = nil,
    limitAmount: Double? = nil,
    unit: String? = nil
  ) {
    self.isEnabled = isEnabled
    self.usedPercent = usedPercent.map { min(max($0, 0), 100) }
    self.usedAmount = usedAmount
    self.limitAmount = limitAmount
    self.unit = unit
  }
}

public struct ProviderUsageSnapshot: Codable, Equatable, Sendable, Identifiable {
  public var id: Harness { harness }
  public var harness: Harness
  public var availability: UsageAvailability
  public var primary: UsageWindow?
  public var secondary: UsageWindow?
  public var modelSpecific: UsageWindow?
  public var overage: UsageOverage?
  public var message: String?
  public var fetchedAt: Date

  public init(
    harness: Harness,
    availability: UsageAvailability = .ok,
    primary: UsageWindow? = nil,
    secondary: UsageWindow? = nil,
    modelSpecific: UsageWindow? = nil,
    overage: UsageOverage? = nil,
    message: String? = nil,
    fetchedAt: Date = Date()
  ) {
    self.harness = harness
    self.availability = availability
    self.primary = primary
    self.secondary = secondary
    self.modelSpecific = modelSpecific
    self.overage = overage
    self.message = message
    self.fetchedAt = fetchedAt
  }
}

public enum UsageParseError: LocalizedError {
  case malformedResponse
  case missingUsage

  public var errorDescription: String? {
    switch self {
    case .malformedResponse: "The usage service returned malformed data."
    case .missingUsage: "The usage service did not return a supported usage bucket."
    }
  }
}

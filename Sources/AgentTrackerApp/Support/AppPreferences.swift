import Foundation

/// UserDefaults keys shared by the model, delegate, and settings UI. Always reference these —
/// a raw string in one place silently forks the preference.
enum PreferenceKeys {
  static let usageMetersEnabled = "usageMetersEnabled"
  static let panelDetached = "panelDetached"
  static let notifyNeedsAttention = "notifyNeedsAttention"
  static let notifyWaiting = "notifyWaiting"
  static let reflowMaximizedTerminal = "reflowMaximizedTerminal"
}

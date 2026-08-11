import AgentTrackerCore
import AppKit

/// Provider logo lookup with a one-time load per provider — the bundle is immutable at runtime,
/// so rows never need to hit the disk again.
@MainActor
enum ProviderLogo {
  private static let images: [Harness: NSImage] = Dictionary(
    uniqueKeysWithValues: ProviderRegistry.all.compactMap { spec in
      guard
        let url = Bundle.module.url(forResource: spec.logoResourceName, withExtension: "png"),
        let image = NSImage(contentsOf: url)
      else { return nil }
      return (spec.harness, image)
    })

  static func image(for harness: Harness) -> NSImage {
    images[harness]
      ?? NSImage(systemSymbolName: "terminal", accessibilityDescription: nil)
      ?? NSImage()
  }
}

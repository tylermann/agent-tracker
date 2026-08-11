import SwiftUI

@main
struct AgentTrackerApplication: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

  var body: some Scene {
    // This scene is unreachable in an .accessory app; AppDelegate owns the real Settings window.
    // The App protocol requires at least one Scene, so declare an empty one.
    Settings {
      EmptyView()
    }
  }
}

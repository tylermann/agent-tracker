import SwiftUI

@main
struct AgentTrackerApplication: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

  var body: some Scene {
    Settings {
      SettingsView(model: appDelegate.model)
    }
  }
}

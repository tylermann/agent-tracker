import AgentTrackerCore
import AppKit
import ApplicationServices
import ServiceManagement
import SwiftUI
import UserNotifications

struct SettingsView: View {
  @ObservedObject var model: AgentTrackerModel
  @State private var integrationMessage = ""
  @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
  @AppStorage(PreferenceKeys.notifyNeedsAttention) private var notifyNeedsAttention = true
  @AppStorage(PreferenceKeys.notifyWaiting) private var notifyWaiting = true
  @AppStorage(PreferenceKeys.reflowMaximizedTerminal) private var reflowMaximizedTerminal = true

  var body: some View {
    Form {
      Section("Integrations") {
        Text(
          "Installs reversible user-level lifecycle hooks and transparent zsh wrappers for Claude, Codex, and Cursor."
        )
        .foregroundStyle(.secondary)
        HStack {
          Button("Install or Repair") { install() }
          Button("Uninstall") { uninstall() }
          Button("Run Doctor") { doctor() }
        }
        if !integrationMessage.isEmpty {
          Text(integrationMessage)
            .font(.caption.monospaced())
            .textSelection(.enabled)
        }
      }

      Section("Permissions") {
        LabeledContent("Accessibility") {
          HStack {
            Text(AXIsProcessTrusted() ? "Granted" : "Required")
            Button("Request") { requestAccessibility() }
            if !AXIsProcessTrusted() {
              Button("Open Settings") { openAccessibilitySettings() }
            }
          }
        }
        LabeledContent("Ghostty Automation") {
          Button("Test Permission") {
            integrationMessage =
              (try? GhosttyAutomation.focusedTerminalID()) != nil
              ? "Ghostty Automation permission is working."
              : "Focus a Ghostty terminal, then try again and accept the macOS Automation prompt."
          }
        }
      }

      Section("Behavior") {
        Toggle("Launch at login", isOn: $launchAtLogin)
          .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
        Toggle("Notify when approval or input is required", isOn: $notifyNeedsAttention)
        Toggle("Notify when a turn completes", isOn: $notifyWaiting)
        Toggle("Leave room for the panel when Ghostty is maximized", isOn: $reflowMaximizedTerminal)
        Text(
          "Maximizing Ghostty — from Raycast, the green button, or a window manager — resizes it to the screen minus the panel's column so the two sit side by side."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        Button("Clear recent history", role: .destructive) { model.clearHistory() }
      }

      Section("Usage meters") {
        Toggle("Show Claude, Codex, and Cursor usage", isOn: $model.usageMetersEnabled)
        Text(
          "When enabled, Agent Tracker polls each provider about every three minutes using that product's existing local sign-in. macOS may ask once to authorize keychain access; after that, polls stay silent. Credentials are read once per launch, kept only in memory, sent only to the matching provider, and never stored by Agent Tracker."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        Text(
          "The usage history chart additionally scans Claude and Codex transcript files on this Mac and stores only per-day token totals per model — never transcript text — and reads Cursor's per-request usage events from the same dashboard endpoint the meter already polls."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }

      Section {
        Text(
          "Prompt previews are capped at 120 characters and transcripts are never stored. Agent Tracker makes no network requests while usage meters are off."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    .padding()
    .frame(
      width: AppConstants.settingsWindowSize.width,
      height: AppConstants.settingsWindowSize.height)
  }

  private func install() {
    do {
      integrationMessage = try IntegrationManager().install(helperPath: helperPath).text
    } catch {
      integrationMessage = error.localizedDescription
    }
  }

  private func uninstall() {
    do {
      integrationMessage = try IntegrationManager().uninstall().text
    } catch {
      integrationMessage = error.localizedDescription
    }
  }

  private func doctor() {
    integrationMessage = IntegrationManager().doctor(helperPath: helperPath).text
  }

  private var helperPath: String {
    Bundle.main.bundleURL.appendingPathComponent(
      "Contents/Helpers/Agent Tracker CLI.app/Contents/MacOS/agent-tracker"
    ).path
  }

  private func requestAccessibility() {
    let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
    _ = AXIsProcessTrustedWithOptions(options)
  }

  private func openAccessibilitySettings() {
    guard
      let url = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    else { return }
    NSWorkspace.shared.open(url)
  }

  private func setLaunchAtLogin(_ enabled: Bool) {
    do {
      if enabled {
        try SMAppService.mainApp.register()
      } else {
        try SMAppService.mainApp.unregister()
      }
    } catch {
      integrationMessage = "Launch at Login: \(error.localizedDescription)"
      launchAtLogin = SMAppService.mainApp.status == .enabled
    }
  }
}

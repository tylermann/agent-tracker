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
  @AppStorage("notifyNeedsAttention") private var notifyNeedsAttention = true
  @AppStorage("notifyWaiting") private var notifyWaiting = true

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
        Button("Clear recent history", role: .destructive) { model.clearHistory() }
      }

      Section {
        Text(
          "Prompt previews are capped at 120 characters. Transcripts are never stored, and Agent Tracker makes no network requests."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    .padding()
    .frame(width: 560, height: 560)
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
    Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/agent-tracker").path
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

import AgentTrackerCore
import AppKit
import Combine
import SwiftUI
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
  let model = AgentTrackerModel()
  private var panelController: PanelController!
  private var statusItem: NSStatusItem!
  private var settingsWindow: NSWindow?
  private var cancellable: AnyCancellable?

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)
    UserDefaults.standard.register(defaults: [
      "notifyNeedsAttention": true,
      "notifyWaiting": true,
    ])
    panelController = PanelController(model: model)
    configureStatusItem()
    configureNotifications()
    model.onAttention = { [weak self] run, kind in self?.notify(run: run, kind: kind) }
    cancellable = model.$runs.sink { [weak self] _ in self?.rebuildMenu() }
    model.start()
    panelController.start()
  }

  func applicationWillTerminate(_ notification: Notification) {
    model.stop()
  }

  private func configureStatusItem() {
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    statusItem.button?.image = NSImage(
      systemSymbolName: "person.2.circle", accessibilityDescription: "Agent Tracker")
    rebuildMenu()
  }

  private func configureNotifications() {
    let center = UNUserNotificationCenter.current()
    center.delegate = self
    center.requestAuthorization(options: [.alert, .badge, .sound]) { _, _ in }
  }

  private func rebuildMenu() {
    guard statusItem != nil else { return }
    statusItem.button?.title = model.unreadCount > 0 ? " \(model.unreadCount)" : ""
    let menu = NSMenu()
    menu.addItem(menuItem("Show Agent Tracker", action: #selector(showPanel)))
    menu.addItem(
      menuItem(
        model.isDetached ? "Attach to Ghostty" : "Reattach to Ghostty",
        action: #selector(attachPanel)))
    let attention = model.needsYou.prefix(8)
    if !attention.isEmpty {
      menu.addItem(.separator())
      let heading = NSMenuItem(title: "Needs You", action: nil, keyEquivalent: "")
      heading.isEnabled = false
      menu.addItem(heading)
      for run in attention {
        let title = "\(run.harness.displayName) — \(projectName(run))"
        let item = menuItem(title, action: #selector(focusRun(_:)))
        item.representedObject = run.runID
        menu.addItem(item)
      }
    }
    menu.addItem(.separator())
    menu.addItem(menuItem("Settings…", action: #selector(showSettings)))
    menu.addItem(menuItem("Quit Agent Tracker", action: #selector(quit)))
    statusItem.menu = menu
  }

  private func menuItem(_ title: String, action: Selector) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
    item.target = self
    return item
  }

  private func projectName(_ run: TrackedRun) -> String {
    let path = run.projectRoot ?? run.workingDirectory
    return path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Unknown project"
  }

  private func notify(run: TrackedRun, kind: AgentEventKind) {
    let defaults = UserDefaults.standard
    if kind == .attentionRequired, !defaults.bool(forKey: "notifyNeedsAttention") { return }
    if kind == .turnStopped, !defaults.bool(forKey: "notifyWaiting") { return }
    let content = UNMutableNotificationContent()
    content.title =
      kind == .attentionRequired
      ? "\(run.harness.displayName) needs attention" : "\(run.harness.displayName) finished a turn"
    content.body = run.promptPreview ?? projectName(run)
    content.threadIdentifier = run.runID
    content.userInfo = ["runID": run.runID]
    if kind == .attentionRequired { content.sound = .default }
    let request = UNNotificationRequest(identifier: run.runID, content: content, trigger: nil)
    UNUserNotificationCenter.current().add(request)
  }

  @objc private func showPanel() { panelController.show() }
  @objc private func attachPanel() { panelController.attach() }

  @objc private func focusRun(_ sender: NSMenuItem) {
    guard let runID = sender.representedObject as? String,
      let run = model.runs.first(where: { $0.runID == runID })
    else { return }
    model.focus(run)
  }

  @objc private func showSettings() {
    if settingsWindow == nil {
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 560, height: 640),
        styleMask: [.titled, .closable, .miniaturizable],
        backing: .buffered,
        defer: false
      )
      window.title = "Agent Tracker Settings"
      window.contentView = NSHostingView(rootView: SettingsView(model: model))
      window.isReleasedWhenClosed = false
      window.center()
      settingsWindow = window
    }
    NSApp.activate(ignoringOtherApps: true)
    settingsWindow?.makeKeyAndOrderFront(nil)
  }

  @objc private func quit() { NSApp.terminate(nil) }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse
  ) async {
    guard let runID = response.notification.request.content.userInfo["runID"] as? String else {
      return
    }
    await MainActor.run {
      guard let run = model.runs.first(where: { $0.runID == runID }) else { return }
      model.focus(run)
      panelController.show()
    }
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification
  ) async -> UNNotificationPresentationOptions {
    [.banner, .list, .sound]
  }
}

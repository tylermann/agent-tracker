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
  private var focusSidebarHotKey: GlobalHotKey?
  private var nextNeedsYouHotKey: GlobalHotKey?
  private var lastFocusedNeedsYouRunID: String?

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)
    UserDefaults.standard.register(defaults: [
      PreferenceKeys.notifyNeedsAttention: true,
      PreferenceKeys.notifyWaiting: true,
    ])
    panelController = PanelController(model: model)
    configureStatusItem()
    configureNotifications()
    model.onAttention = { [weak self] run, kind in self?.notify(run: run, kind: kind) }
    cancellable = model.$runs.sink { [weak self] _ in self?.rebuildMenu() }
    configureHotKey()
    model.start()
    panelController.start()
  }

  func applicationWillTerminate(_ notification: Notification) {
    focusSidebarHotKey?.unregister()
    nextNeedsYouHotKey?.unregister()
    model.stop()
  }

  private func configureHotKey() {
    focusSidebarHotKey = GlobalHotKey(
      keyCode: GlobalHotKey.FocusSidebar.keyCode,
      modifiers: GlobalHotKey.FocusSidebar.modifiers
    ) { [weak self] in
      self?.panelController.focusForKeyboardNavigation()
    }
    if focusSidebarHotKey == nil {
      model.errorMessage = "Another app already uses ⌘⇧' — the sidebar shortcut is unavailable."
    }

    nextNeedsYouHotKey = GlobalHotKey(
      keyCode: GlobalHotKey.NextNeedsYou.keyCode,
      modifiers: GlobalHotKey.NextNeedsYou.modifiers
    ) { [weak self] in
      self?.focusNextNeedsYouRun()
    }
    if nextNeedsYouHotKey == nil {
      model.errorMessage =
        "Another app already uses ⌘⇧\\ — the next-agent shortcut is unavailable."
    }
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
    let show = menuItem("Show Agent Tracker", action: #selector(showPanel))
    show.keyEquivalent = GlobalHotKey.FocusSidebar.displayKeyEquivalent
    show.keyEquivalentModifierMask = GlobalHotKey.FocusSidebar.displayModifiers
    menu.addItem(show)
    let nextNeedsYou = menuItem(
      "Next Agent Needing Me", action: #selector(focusNextNeedsYouRun))
    nextNeedsYou.keyEquivalent = GlobalHotKey.NextNeedsYou.displayKeyEquivalent
    nextNeedsYou.keyEquivalentModifierMask = GlobalHotKey.NextNeedsYou.displayModifiers
    menu.addItem(nextNeedsYou)
    menu.addItem(
      menuItem(
        model.isDetached ? "Attach to Ghostty" : "Reattach to Ghostty",
        action: #selector(attachPanel)))
    let attention = model.needsYou.prefix(8)
    if !attention.isEmpty {
      menu.addItem(.separator())
      let heading = NSMenuItem(title: "Needs Me", action: nil, keyEquivalent: "")
      heading.isEnabled = false
      menu.addItem(heading)
      for run in attention {
        let title = "\(run.harness.displayName) — \(RunPresentation.projectName(run))"
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

  private func notify(run: TrackedRun, kind: AgentEventKind) {
    let defaults = UserDefaults.standard
    if kind == .attentionRequired, !defaults.bool(forKey: PreferenceKeys.notifyNeedsAttention) {
      return
    }
    if kind == .turnStopped, !defaults.bool(forKey: PreferenceKeys.notifyWaiting) { return }
    let content = UNMutableNotificationContent()
    content.title =
      kind == .attentionRequired
      ? "\(run.harness.displayName) needs attention" : "\(run.harness.displayName) finished a turn"
    content.body =
      run.promptPreview.map { EventMapper.promptPreview($0, limit: 120) }
      ?? RunPresentation.projectName(run)
    content.threadIdentifier = run.runID
    content.userInfo = ["runID": run.runID]
    if kind == .attentionRequired { content.sound = .default }
    let request = UNNotificationRequest(identifier: run.runID, content: content, trigger: nil)
    UNUserNotificationCenter.current().add(request)
  }

  @objc private func showPanel() { panelController.focusForKeyboardNavigation() }
  @objc private func attachPanel() { panelController.attach() }

  /// Walks the attention queue from oldest to newest and wraps at the end. The last run stays in
  /// the queue after it is focused (focusing marks it read, but it is still blocked), so repeated
  /// presses reliably cycle through every agent that needs the user.
  @objc private func focusNextNeedsYouRun() {
    let queue = model.needsYou.sorted {
      if $0.lastEventAt != $1.lastEventAt { return $0.lastEventAt < $1.lastEventAt }
      if $0.startedAt != $1.startedAt { return $0.startedAt < $1.startedAt }
      return $0.runID < $1.runID
    }
    guard !queue.isEmpty else {
      lastFocusedNeedsYouRunID = nil
      panelController.focusForKeyboardNavigation()
      return
    }

    let nextIndex: Int
    if let lastFocusedNeedsYouRunID,
      let currentIndex = queue.firstIndex(where: { $0.runID == lastFocusedNeedsYouRunID })
    {
      nextIndex = (currentIndex + 1) % queue.count
    } else {
      nextIndex = 0
    }
    let run = queue[nextIndex]
    lastFocusedNeedsYouRunID = run.runID
    model.focus(run)
    panelController.show()
  }

  @objc private func focusRun(_ sender: NSMenuItem) {
    guard let runID = sender.representedObject as? String,
      let run = model.runs.first(where: { $0.runID == runID })
    else { return }
    model.focus(run)
  }

  @objc private func showSettings() {
    if settingsWindow == nil {
      let window = NSWindow(
        contentRect: NSRect(origin: .zero, size: AppConstants.settingsWindowSize),
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

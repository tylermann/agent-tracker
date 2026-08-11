import AgentTrackerCore
import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Combine
import SwiftUI

@MainActor
final class PanelController: NSObject, NSWindowDelegate {
  let panel: NSPanel
  private let model: AgentTrackerModel
  private var timer: Timer?
  private var isProgrammaticMove = false
  private var userHidden = false
  private var cancellable: AnyCancellable?
  private var activationObserver: NSObjectProtocol?
  private var resignKeyObserver: NSObjectProtocol?
  private var keyMonitor: Any?
  private var isKeyboardNavigating = false
  private var appToRestore: NSRunningApplication?

  init(model: AgentTrackerModel) {
    self.model = model
    panel = NSPanel(
      contentRect: NSRect(x: 100, y: 100, width: 320, height: 620),
      styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    super.init()
    // Keep the native frame for resize and drag support, but let the sidebar content
    // occupy the title-bar area. The panel is controlled from the menu-bar item, so
    // its traffic-light controls add visual noise without providing a useful action.
    panel.styleMask.insert(.fullSizeContentView)
    panel.titleVisibility = .hidden
    panel.titlebarAppearsTransparent = true
    panel.standardWindowButton(.closeButton)?.isHidden = true
    panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
    panel.standardWindowButton(.zoomButton)?.isHidden = true
    panel.isFloatingPanel = false
    panel.becomesKeyOnlyIfNeeded = true
    panel.level = .normal
    panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false
    panel.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
    panel.minSize = NSSize(width: 280, height: 360)
    panel.contentView = NSHostingView(rootView: SidebarView(model: model))
    panel.delegate = self
    cancellable = model.$isDetached.sink { [weak self] detached in
      guard !detached else { return }
      self?.updatePosition()
    }
  }

  func start() {
    requestAccessibilityIfNeeded()
    activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didActivateApplicationNotification,
      object: nil,
      queue: .main
    ) { [weak self] notification in
      guard
        let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
          as? NSRunningApplication,
        Self.isGhostty(application)
      else { return }
      Task { @MainActor in
        self?.updatePosition(forceOrderFront: true)
      }
    }
    timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.updatePosition() }
    }
    panel.orderFrontRegardless()
    updatePosition()
  }

  func show() {
    userHidden = false
    panel.orderFrontRegardless()
    if !model.isDetached { updatePosition(forceOrderFront: true) }
  }

  func attach() {
    model.isDetached = false
    show()
  }

  /// Brings the panel forward and hands it the keyboard so arrows move the highlight and Return
  /// focuses the highlighted run. Invoked from the global hot key, so the frontmost app is usually
  /// Ghostty and this app has to activate itself to receive key events at all.
  func focusForKeyboardNavigation() {
    show()
    if let frontmost = NSWorkspace.shared.frontmostApplication,
      frontmost.processIdentifier != ProcessInfo.processInfo.processIdentifier
    {
      appToRestore = frontmost
    }
    model.beginKeyboardSelection()
    isKeyboardNavigating = true
    // The panel is deliberately click-through the rest of the time; allow it to take key status for
    // the duration of keyboard navigation only.
    panel.becomesKeyOnlyIfNeeded = false
    NSApp.activate(ignoringOtherApps: true)
    panel.makeKeyAndOrderFront(nil)
    installKeyMonitor()
    observeResignKey()
  }

  private func installKeyMonitor() {
    guard keyMonitor == nil else { return }
    keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      self?.handleKeyDown(event) ?? event
    }
  }

  private func observeResignKey() {
    guard resignKeyObserver == nil else { return }
    resignKeyObserver = NotificationCenter.default.addObserver(
      forName: NSWindow.didResignKeyNotification,
      object: panel,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor in self?.endKeyboardNavigation(reactivatingPreviousApp: false) }
    }
  }

  private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
    guard isKeyboardNavigating, event.window === panel else { return event }
    switch Int(event.keyCode) {
    case kVK_UpArrow:
      model.moveSelection(by: -1)
    case kVK_DownArrow:
      model.moveSelection(by: 1)
    case kVK_Return, kVK_ANSI_KeypadEnter:
      // `focus` activates Ghostty itself, so there is no previous app left to restore.
      if model.activateSelection() { endKeyboardNavigation(reactivatingPreviousApp: false) }
    case kVK_Escape:
      endKeyboardNavigation(reactivatingPreviousApp: true)
    default:
      return event
    }
    return nil
  }

  private func endKeyboardNavigation(reactivatingPreviousApp: Bool) {
    guard isKeyboardNavigating else { return }
    isKeyboardNavigating = false
    model.endKeyboardSelection()
    panel.becomesKeyOnlyIfNeeded = true
    if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    keyMonitor = nil
    if let resignKeyObserver { NotificationCenter.default.removeObserver(resignKeyObserver) }
    resignKeyObserver = nil
    let previous = appToRestore
    appToRestore = nil
    if reactivatingPreviousApp, let previous, !previous.isTerminated {
      previous.activate()
    }
  }

  func windowDidMove(_ notification: Notification) {
    if !isProgrammaticMove, panel.isVisible {
      model.isDetached = true
    }
  }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    userHidden = true
    panel.orderOut(nil)
    return false
  }

  private func requestAccessibilityIfNeeded() {
    guard !AXIsProcessTrusted() else { return }
    let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
    _ = AXIsProcessTrustedWithOptions(options)
  }

  private func updatePosition(forceOrderFront: Bool = false) {
    guard !userHidden else { return }
    guard !model.isDetached else { return }
    guard let app = NSWorkspace.shared.runningApplications.first(where: Self.isGhostty),
      !app.isHidden
    else {
      if forceOrderFront { panel.orderFrontRegardless() }
      return
    }
    guard let windowRect = focusedWindowRect(processID: app.processIdentifier) else {
      // Accessibility can be unavailable briefly during app/Space activation, and ad-hoc
      // development builds lose their grant whenever their code signature changes. Keep the
      // panel at its last known position instead of making Show flash and immediately disappear.
      if forceOrderFront { panel.orderFrontRegardless() }
      return
    }
    let screen = screen(containingQuartzRect: windowRect)

    let width = panel.frame.width
    let desiredHeight = max(
      panel.minSize.height, min(windowRect.height, screen.visibleFrame.height))
    let gap: CGFloat = 8
    let rightSpace = screen.visibleFrame.maxX - windowRect.maxX
    let leftSpace = windowRect.minX - screen.visibleFrame.minX
    let x: CGFloat
    if rightSpace >= width + gap {
      x = windowRect.maxX + gap
    } else if leftSpace >= width + gap {
      x = windowRect.minX - width - gap
    } else {
      x = min(
        max(windowRect.maxX - width, screen.visibleFrame.minX), screen.visibleFrame.maxX - width)
    }
    let y = min(
      max(windowRect.minY, screen.visibleFrame.minY), screen.visibleFrame.maxY - desiredHeight)
    let frame = NSRect(x: x, y: y, width: width, height: desiredHeight)
    isProgrammaticMove = true
    panel.setFrame(frame, display: true, animate: false)
    isProgrammaticMove = false
    if forceOrderFront || !panel.isVisible { panel.orderFrontRegardless() }
  }

  nonisolated private static func isGhostty(_ application: NSRunningApplication) -> Bool {
    application.bundleIdentifier == "com.mitchellh.ghostty"
      || application.localizedName == "Ghostty"
  }

  private func focusedWindowRect(processID: pid_t) -> CGRect? {
    let application = AXUIElementCreateApplication(processID)
    var windowValue: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(
        application,
        kAXFocusedWindowAttribute as CFString,
        &windowValue
      ) == .success,
      let windowValue
    else { return nil }
    let window = windowValue as! AXUIElement
    var positionValue: CFTypeRef?
    var sizeValue: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionValue)
        == .success,
      AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue) == .success,
      let positionValue, let sizeValue
    else { return nil }
    var point = CGPoint.zero
    var size = CGSize.zero
    guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &point),
      AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
    else { return nil }
    let quartzRect = CGRect(origin: point, size: size)
    guard let screen = screenForQuartzRect(quartzRect) else { return nil }
    let displayID =
      screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
    let quartzScreen = CGDisplayBounds(displayID)
    return CGRect(
      x: screen.frame.minX + (point.x - quartzScreen.minX),
      y: screen.frame.maxY - (point.y - quartzScreen.minY) - size.height,
      width: size.width,
      height: size.height
    )
  }

  private func screenForQuartzRect(_ rect: CGRect) -> NSScreen? {
    NSScreen.screens.max { first, second in
      quartzIntersection(first, rect).area < quartzIntersection(second, rect).area
    }
  }

  private func quartzIntersection(_ screen: NSScreen, _ rect: CGRect) -> CGRect {
    let displayID =
      screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
    return CGDisplayBounds(displayID).intersection(rect)
  }

  private func screen(containingQuartzRect rect: CGRect) -> NSScreen {
    NSScreen.screens.first(where: { $0.frame.intersects(rect) }) ?? NSScreen.main!
  }
}

extension CGRect {
  fileprivate var area: CGFloat { isNull ? 0 : width * height }
}

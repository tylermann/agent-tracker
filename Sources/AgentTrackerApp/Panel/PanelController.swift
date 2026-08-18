import AgentTrackerCore
import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Combine
import SwiftUI

@MainActor
final class PanelController: NSObject, NSWindowDelegate {
  private let panel: KeyboardNavigationPanel
  private let model: AgentTrackerModel
  private var timer: Timer?
  private var isProgrammaticMove = false
  private var userHidden = false
  private var cancellable: AnyCancellable?
  private var activationObserver: NSObjectProtocol?
  private var resignKeyObserver: NSObjectProtocol?
  private var isKeyboardNavigating = false
  private var appToRestore: NSRunningApplication?
  private var screenChangeObserver: NSObjectProtocol?
  private var wakeObserver: NSObjectProtocol?
  private var ignoreMovesUntil: Date = .distantPast

  init(model: AgentTrackerModel) {
    self.model = model
    panel = KeyboardNavigationPanel(
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
    // Ghostty stays frontmost, so this accessory app is inactive whenever the user is hovering
    // the sidebar. Without this, every SwiftUI `.help()` tooltip is suppressed.
    panel.allowsToolTipsWhenApplicationIsInactive = true
    panel.level = .normal
    panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false
    panel.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
    panel.minSize = NSSize(width: 280, height: 360)
    panel.contentView = NSHostingView(rootView: SidebarView(model: model))
    panel.delegate = self
    panel.keyDownHandler = { [weak self] event in
      self?.handleKeyDown(event) == nil
    }
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
        self?.model.refreshFocusedRun()
      }
    }
    screenChangeObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor in self?.reanchorAfterDisplayChange() }
    }
    wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didWakeNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor in
        self?.reanchorAfterDisplayChange()
        // Give the interface a moment to come back before hitting usage endpoints.
        try? await Task.sleep(for: .seconds(2))
        self?.model.pollUsageNow()
      }
    }
    timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
      Task { @MainActor in
        self?.updatePosition()
        self?.model.refreshFocusedRun()
      }
    }
    panel.orderFrontRegardless()
    updatePosition()
    model.refreshFocusedRun()
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
  /// activates the highlighted run (focus a live terminal, or resume a Recent session). Invoked
  /// from the global hot key, so the frontmost app is usually Ghostty and this app has to activate
  /// itself to receive key events at all.
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
    observeResignKey()
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
    case kVK_RightArrow:
      model.expandSelection()
    case kVK_LeftArrow:
      model.collapseSelection()
    case kVK_Return, kVK_ANSI_KeypadEnter:
      // Both focus and resume activate Ghostty, so there is no previous app left to restore.
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
    if let resignKeyObserver { NotificationCenter.default.removeObserver(resignKeyObserver) }
    resignKeyObserver = nil
    let previous = appToRestore
    appToRestore = nil
    if reactivatingPreviousApp, let previous, !previous.isTerminated {
      previous.activate()
    }
  }

  func windowDidMove(_ notification: Notification) {
    guard !isProgrammaticMove, panel.isVisible else { return }
    // Detaching is meant to record "the user dragged the panel somewhere they want it". AppKit also
    // relocates windows on its own when the display set changes — closing the lid, waking, or
    // unplugging a monitor — and those moves arrive here indistinguishable from a drag. Since the
    // flag persists, one sleep/wake cycle used to leave the panel detached until Attach was clicked.
    // A real drag always holds the left button down, and display shuffles never do.
    guard NSEvent.pressedMouseButtons & 1 != 0, Date() >= ignoreMovesUntil else { return }
    model.isDetached = true
  }

  /// Displays coming and going leave the panel wherever AppKit parked it, so re-run the anchoring
  /// pass immediately instead of waiting on the timer, and ignore the moves AppKit makes settling
  /// the new layout.
  private func reanchorAfterDisplayChange() {
    ignoreMovesUntil = Date().addingTimeInterval(3)
    updatePosition(forceOrderFront: true)
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
    guard let window = focusedWindow(processID: app.processIdentifier),
      var windowRect = rect(of: window)
    else {
      // Accessibility can be unavailable briefly during app/Space activation, and ad-hoc
      // development builds lose their grant whenever their code signature changes. Keep the
      // panel at its last known position instead of making Show flash and immediately disappear.
      if forceOrderFront { panel.orderFrontRegardless() }
      return
    }
    let screen = screen(containingQuartzRect: windowRect)

    let width = panel.frame.width
    if reflowMaximizedTerminal,
      let reflowed = shrinkIfMaximized(window, rect: windowRect, screen: screen, panelWidth: width)
    {
      windowRect = reflowed
    }
    let desiredHeight = max(
      panel.minSize.height, min(windowRect.height, screen.visibleFrame.height))
    let rightSpace = screen.visibleFrame.maxX - windowRect.maxX
    let leftSpace = windowRect.minX - screen.visibleFrame.minX
    let x: CGFloat
    if rightSpace >= width {
      x = windowRect.maxX
    } else if leftSpace >= width {
      x = windowRect.minX - width
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

  private var reflowMaximizedTerminal: Bool {
    UserDefaults.standard.object(forKey: PreferenceKeys.reflowMaximizedTerminal) as? Bool ?? true
  }

  /// Raycast's "Maximize" (and the green zoom button) fill the whole visible frame, which buries the
  /// panel behind the terminal. Give the terminal back everything except the panel's column so the
  /// two tile side by side instead. Returns the new terminal rect, or nil when nothing was resized.
  private func shrinkIfMaximized(
    _ window: AXUIElement, rect currentRect: CGRect, screen: NSScreen, panelWidth: CGFloat
  ) -> CGRect? {
    let visible = screen.visibleFrame
    let tolerance: CGFloat = 12
    // A native-fullscreen window covers the menu bar, so it is taller than the visible frame. Those
    // windows own their Space and must not be resized.
    guard currentRect.height <= visible.height + tolerance else { return nil }
    guard currentRect.minX <= visible.minX + tolerance,
      currentRect.maxX >= visible.maxX - tolerance,
      currentRect.minY <= visible.minY + tolerance,
      currentRect.maxY >= visible.maxY - tolerance
    else { return nil }
    let targetWidth = visible.width - panelWidth
    guard targetWidth >= 200 else { return nil }
    // The window is already flush with the left edge of the visible frame, so only the width
    // changes; leaving the position alone avoids a second AX write that could fight the terminal.
    var size = CGSize(width: targetWidth, height: currentRect.height)
    guard let sizeValue = AXValueCreate(.cgSize, &size) else { return nil }
    guard AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue) == .success
    else { return nil }
    return rect(of: window) ?? CGRect(origin: currentRect.origin, size: size)
  }

  private func focusedWindow(processID: pid_t) -> AXUIElement? {
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
    return (windowValue as! AXUIElement)
  }

  private func rect(of window: AXUIElement) -> CGRect? {
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

/// Consumes keyboard-navigation events before AppKit routes them through the responder chain,
/// which would otherwise play the system alert sound for an unhandled arrow key.
private final class KeyboardNavigationPanel: NSPanel {
  var keyDownHandler: ((NSEvent) -> Bool)?

  override func sendEvent(_ event: NSEvent) {
    if event.type == .keyDown, keyDownHandler?(event) == true { return }
    super.sendEvent(event)
  }
}

extension CGRect {
  fileprivate var area: CGFloat { isNull ? 0 : width * height }
}

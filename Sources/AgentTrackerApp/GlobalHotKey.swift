import AppKit
import Carbon.HIToolbox

/// A system-wide hot key registered through Carbon's `RegisterEventHotKey`.
///
/// The sidebar lives in a non-activating panel that never becomes key while Ghostty is frontmost,
/// so a SwiftUI `.keyboardShortcut` or a local event monitor would never see the keystroke. A
/// Carbon hot key is registered with the window server instead: it fires regardless of which app is
/// active and swallows the key combination, so the shortcut never leaks through to the terminal.
/// Unlike an event tap it needs no entitlement and no accessibility grant.
@MainActor
final class GlobalHotKey {
  /// Four-character code ('AGTK') identifying hot keys owned by this app.
  private static let signature: OSType = 0x4147_544B
  private static var nextIdentifier: UInt32 = 1
  private static var actions: [UInt32: () -> Void] = [:]

  private let identifier: UInt32
  private var hotKeyRef: EventHotKeyRef?
  private var handlerRef: EventHandlerRef?

  /// Returns `nil` when the combination is already claimed by another application.
  init?(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
    identifier = Self.nextIdentifier
    Self.nextIdentifier += 1

    var eventType = EventTypeSpec(
      eventClass: OSType(kEventClassKeyboard),
      eventKind: UInt32(kEventHotKeyPressed)
    )
    var handler: EventHandlerRef?
    guard
      InstallEventHandler(
        GetApplicationEventTarget(), globalHotKeyEventHandler, 1, &eventType, nil, &handler)
        == noErr
    else { return nil }

    var ref: EventHotKeyRef?
    let hotKeyID = EventHotKeyID(signature: Self.signature, id: identifier)
    guard
      RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        == noErr,
      let ref
    else {
      if let handler { RemoveEventHandler(handler) }
      return nil
    }

    handlerRef = handler
    hotKeyRef = ref
    Self.actions[identifier] = action
  }

  func unregister() {
    if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
    if let handlerRef { RemoveEventHandler(handlerRef) }
    hotKeyRef = nil
    handlerRef = nil
    Self.actions[identifier] = nil
  }

  fileprivate static func fire(identifier: UInt32) {
    actions[identifier]?()
  }
}

/// Carbon invokes this as a C function pointer, so it cannot capture context; the hot key's numeric
/// identifier is read back out of the event and mapped to its action on the main actor.
private func globalHotKeyEventHandler(
  _ callRef: EventHandlerCallRef?,
  _ event: EventRef?,
  _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
  var hotKeyID = EventHotKeyID()
  let status = GetEventParameter(
    event,
    EventParamName(kEventParamDirectObject),
    EventParamType(typeEventHotKeyID),
    nil,
    MemoryLayout<EventHotKeyID>.size,
    nil,
    &hotKeyID
  )
  guard status == noErr else { return status }
  let identifier = hotKeyID.id
  Task { @MainActor in GlobalHotKey.fire(identifier: identifier) }
  return noErr
}

extension GlobalHotKey {
  /// ⌘⇧' — focuses the sidebar for keyboard navigation.
  enum FocusSidebar {
    static let keyCode = UInt32(kVK_ANSI_Quote)
    static let modifiers = UInt32(cmdKey | shiftKey)
    static let displayKeyEquivalent = "'"
    static let displayModifiers: NSEvent.ModifierFlags = [.command, .shift]
  }
}

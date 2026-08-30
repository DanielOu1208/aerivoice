import AppKit

enum ModifierShortcutDecision: Equatable {
  case passThrough
  case consume
  case trigger
}

struct ModifierShortcutLatch {
  private(set) var isActive = false

  mutating func flagsChanged(current: UInt64, required: UInt64) -> ModifierShortcutDecision {
    if isActive {
      if current & required == 0 { isActive = false }
      return .consume
    }
    guard current == required else { return .passThrough }
    isActive = true
    return .trigger
  }

  mutating func reset() { isActive = false }
}

enum TargetedPasteEvent {
  static let marker: Int64 = 0x4145_5249

  static func makePair() -> (down: CGEvent, up: CGEvent)? {
    guard let source = CGEventSource(stateID: .combinedSessionState) else { return nil }
    source.userData = marker
    guard
      let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
      let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
    else { return nil }
    down.flags = .maskCommand
    up.flags = .maskCommand
    return (down, up)
  }

  static func post(to processIdentifier: pid_t) -> Bool {
    guard let events = makePair() else { return false }
    events.down.postToPid(processIdentifier)
    events.up.postToPid(processIdentifier)
    return true
  }
}

@MainActor
final class GlobalShortcutMonitor {
  var onToggle: (() -> Void)?
  var onCancel: (() -> Void)?
  var shouldCancel: (() -> Bool)?

  private var tap: CFMachPort?
  private var source: CFRunLoopSource?
  private var definition: ShortcutDefinition?
  private var modifierLatch = ModifierShortcutLatch()
  private var shortcutPressed = false

  func start(definition: ShortcutDefinition) {
    stop()
    self.definition = definition
    let mask =
      (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
      | (1 << CGEventType.flagsChanged.rawValue)
    let callback: CGEventTapCallBack = { _, type, event, userInfo in
      guard let userInfo else { return Unmanaged.passUnretained(event) }
      let monitor = Unmanaged<GlobalShortcutMonitor>.fromOpaque(userInfo).takeUnretainedValue()
      if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        monitor.resetPressedState()
        if let tap = monitor.tap { CGEvent.tapEnable(tap: tap, enable: true) }
        return Unmanaged.passUnretained(event)
      }
      if event.getIntegerValueField(.eventSourceUserData) == TargetedPasteEvent.marker {
        return Unmanaged.passUnretained(event)
      }
      return monitor.handle(type: type, event: event) ? nil : Unmanaged.passUnretained(event)
    }
    tap = CGEvent.tapCreate(
      tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
      eventsOfInterest: CGEventMask(mask), callback: callback,
      userInfo: Unmanaged.passUnretained(self).toOpaque())
    guard let tap else { return }
    source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
  }

  func stop() {
    if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
    if let tap { CFMachPortInvalidate(tap) }
    source = nil
    tap = nil
    resetPressedState()
  }

  private func resetPressedState() {
    shortcutPressed = false
    modifierLatch.reset()
  }

  private func handle(type: CGEventType, event: CGEvent) -> Bool {
    guard let definition else { return false }
    let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
    let flags = event.flags.intersection([
      .maskCommand, .maskControl, .maskAlternate, .maskShift, .maskSecondaryFn,
    ])
    if definition.isModifierOnly, type == .flagsChanged {
      switch modifierLatch.flagsChanged(
        current: flags.rawValue, required: UInt64(definition.modifiers))
      {
      case .trigger:
        onToggle?()
        return true
      case .consume:
        return true
      case .passThrough:
        break
      }
    }
    if type == .keyDown, keyCode == 53 {
      guard shouldCancel?() == true else { return false }
      onCancel?()
      return true
    }
    guard !definition.isModifierOnly else { return false }
    if type == .keyDown, keyCode == definition.keyCode,
      flags.rawValue == UInt64(definition.modifiers)
    {
      if event.getIntegerValueField(.keyboardEventAutorepeat) == 0, !shortcutPressed {
        shortcutPressed = true
        onToggle?()
      }
      return true
    }
    if type == .keyUp, keyCode == definition.keyCode {
      let consumed = shortcutPressed
      shortcutPressed = false
      return consumed
    }
    return false
  }
}

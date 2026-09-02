import AppKit

enum ModifierShortcutDecision: Equatable {
  case passThrough
  case consume
  case press
  case release
}

struct ModifierShortcutLatch {
  private(set) var isActive = false
  private var deliveredRelease = false

  mutating func flagsChanged(current: UInt64, required: UInt64) -> ModifierShortcutDecision {
    if isActive {
      if !deliveredRelease, current & required != required {
        deliveredRelease = true
        if current & required == 0 { reset() }
        return .release
      }
      if current & required == 0 { reset() }
      return .consume
    }
    guard current == required else { return .passThrough }
    isActive = true
    return .press
  }

  mutating func reset() {
    isActive = false
    deliveredRelease = false
  }
}

struct ShortcutPressTracker {
  static let holdThreshold: CGEventTimestamp = 350_000_000

  private(set) var isPressed = false
  private var pressedAt: CGEventTimestamp = 0
  private var finishesOnRelease = false

  mutating func press(at timestamp: CGEventTimestamp, finishesOnRelease: Bool) {
    guard !isPressed else { return }
    isPressed = true
    pressedAt = timestamp
    self.finishesOnRelease = finishesOnRelease
  }

  mutating func release(at timestamp: CGEventTimestamp) -> Bool {
    guard isPressed else { return false }
    defer { reset() }
    guard finishesOnRelease, timestamp >= pressedAt else { return false }
    return timestamp - pressedAt >= Self.holdThreshold
  }

  mutating func reset() {
    isPressed = false
    pressedAt = 0
    finishesOnRelease = false
  }
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
  var onPress: (() -> UUID?)?
  var onHoldRelease: ((UUID) -> Void)?
  var onCancel: (() -> Void)?
  var shouldCancel: (() -> Bool)?

  private var tap: CFMachPort?
  private var source: CFRunLoopSource?
  private var definition: ShortcutDefinition?
  private var activationMode = ShortcutActivationMode.hybrid
  private var modifierLatch = ModifierShortcutLatch()
  private var pressTracker = ShortcutPressTracker()
  private var heldLifecycleGeneration: UUID?

  func start(definition: ShortcutDefinition, activationMode: ShortcutActivationMode) {
    if self.definition == definition, self.activationMode == activationMode, let tap,
      CFMachPortIsValid(tap)
    {
      return
    }
    stop()
    self.definition = definition
    self.activationMode = activationMode
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
    definition = nil
    resetPressedState()
  }

  private func resetPressedState() {
    pressTracker.reset()
    modifierLatch.reset()
    heldLifecycleGeneration = nil
  }

  private func press(at timestamp: CGEventTimestamp) {
    let lifecycleGeneration = onPress?()
    heldLifecycleGeneration = activationMode == .hybrid ? lifecycleGeneration : nil
    pressTracker.press(
      at: timestamp, finishesOnRelease: heldLifecycleGeneration != nil)
  }

  private func release(at timestamp: CGEventTimestamp) {
    let shouldFinish = pressTracker.release(at: timestamp)
    let lifecycleGeneration = heldLifecycleGeneration
    heldLifecycleGeneration = nil
    if shouldFinish, let lifecycleGeneration { onHoldRelease?(lifecycleGeneration) }
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
      case .press:
        press(at: event.timestamp)
        return true
      case .release:
        release(at: event.timestamp)
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
      if event.getIntegerValueField(.keyboardEventAutorepeat) == 0, !pressTracker.isPressed {
        press(at: event.timestamp)
      }
      return true
    }
    if type == .keyUp, keyCode == definition.keyCode {
      let consumed = pressTracker.isPressed
      release(at: event.timestamp)
      return consumed
    }
    return false
  }
}

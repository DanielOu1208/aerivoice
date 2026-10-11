import AppKit
import Carbon

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

  /// Every required modifier is still down since the press.
  var isHeld: Bool { isActive && !deliveredRelease }

  /// The press was cancelled while held: changes are consumed, and nothing presses again,
  /// until every required modifier is up.
  mutating func cancelPress() {
    guard isActive else { return }
    deliveredRelease = true
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
  private var activationMode = ShortcutActivationMode.hybrid

  mutating func press(
    at timestamp: CGEventTimestamp, finishesOnRelease: Bool,
    activationMode: ShortcutActivationMode = .hybrid
  ) {
    guard !isPressed else { return }
    isPressed = true
    pressedAt = timestamp
    self.finishesOnRelease = finishesOnRelease
    self.activationMode = activationMode
  }

  mutating func release(at timestamp: CGEventTimestamp) -> Bool {
    guard isPressed else { return false }
    defer { reset() }
    guard finishesOnRelease, timestamp >= pressedAt else { return false }
    switch activationMode {
    case .hold: return true
    case .hybrid: return timestamp - pressedAt >= Self.holdThreshold
    case .toggle: return false
    }
  }

  mutating func reset() {
    isPressed = false
    pressedAt = 0
    finishesOnRelease = false
  }
}

enum TargetedPasteEvent {
  static let marker: Int64 = 0x4145_5249
  /// The V key on QWERTY layouts.
  static let qwertyKeyCode: CGKeyCode = 9

  /// The key that types "v" with Command held in a layout's `kTISPropertyUnicodeKeyLayoutData`.
  /// Apps match Command-V by that character, so on Dvorak the key is 47 and on Turkish-F 8.
  /// Without layout data, or a key that types "v", it is the QWERTY key.
  static func keyCode(forLayoutData data: Data?) -> CGKeyCode {
    guard let data else { return qwertyKeyCode }
    return data.withUnsafeBytes { buffer -> CGKeyCode in
      guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self)
      else { return qwertyKeyCode }
      let keyboardType = UInt32(LMGetKbdType())
      func typesV(_ keyCode: CGKeyCode) -> Bool {
        var deadKeyState: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 4)
        let status = UCKeyTranslate(
          layout, keyCode, UInt16(kUCKeyActionDown), UInt32((cmdKey >> 8) & 0xFF), keyboardType,
          OptionBits(kUCKeyTranslateNoDeadKeysMask), &deadKeyState, characters.count, &length,
          &characters)
        return status == noErr && length == 1 && characters[0] == UniChar(UInt8(ascii: "v"))
      }
      if typesV(qwertyKeyCode) { return qwertyKeyCode }
      return (0..<128).lazy.map { CGKeyCode($0) }.first(where: typesV) ?? qwertyKeyCode
    }
  }

  /// The paste key for the keyboard layout in use. Text Input Sources are read on the main
  /// thread.
  @MainActor
  static func currentKeyCode() -> CGKeyCode {
    guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
      let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
    else { return qwertyKeyCode }
    let data = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue() as Data
    return keyCode(forLayoutData: data)
  }

  static func makePair(keyCode: CGKeyCode) -> (down: CGEvent, up: CGEvent)? {
    guard let source = CGEventSource(stateID: .privateState) else { return nil }
    source.userData = marker
    guard
      let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
      let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
    else { return nil }
    down.flags = .maskCommand
    up.flags = .maskCommand
    return (down, up)
  }

  @MainActor
  static func post(to processIdentifier: pid_t) -> Bool {
    guard let events = makePair(keyCode: currentKeyCode()) else { return false }
    events.down.postToPid(processIdentifier)
    events.up.postToPid(processIdentifier)
    return true
  }
}

@MainActor
final class GlobalShortcutMonitor {
  /// Receives how long ago the key event happened, when known.
  var onPress: ((Duration?) -> UUID?)?
  var onHoldPress: ((Duration?) -> UUID?)?
  var onHoldRelease: ((UUID) -> Void)?
  /// The press that started this dictation began an ordinary key combination instead.
  var onAbort: ((UUID) -> Void)?
  var onCancel: (() -> Void)?
  var shouldCancel: (() -> Bool)?
  var onAvailabilityChange: ((Bool) -> Void)?

  private var tap: CFMachPort?
  private var source: CFRunLoopSource?
  private var definition: ShortcutDefinition?
  private var activationMode = ShortcutActivationMode.hybrid
  private var modifierLatch = ModifierShortcutLatch()
  private var pressTracker = ShortcutPressTracker()
  private var heldLifecycleGeneration: UUID?
  /// A dictation a modifier-only press just started, until the first key-down or the hold
  /// threshold shows whether the modifier begins an ordinary combination such as fn-Delete.
  private var chordWindow: (lifecycleGeneration: UUID, ends: CGEventTimestamp)?

  func start(definition: ShortcutDefinition, activationMode: ShortcutActivationMode) {
    if self.definition == definition, self.activationMode == activationMode, let tap,
      CFMachPortIsValid(tap)
    {
      onAvailabilityChange?(CGEvent.tapIsEnabled(tap: tap))
      return
    }
    stop()
    configure(definition: definition, activationMode: activationMode)
    let mask =
      (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
      | (1 << CGEventType.flagsChanged.rawValue)
    let callback: CGEventTapCallBack = { _, type, event, userInfo in
      guard let userInfo else { return Unmanaged.passUnretained(event) }
      let monitor = Unmanaged<GlobalShortcutMonitor>.fromOpaque(userInfo).takeUnretainedValue()
      if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        monitor.releaseHeldSessionOnMonitoringLoss()
        if let tap = monitor.tap { CGEvent.tapEnable(tap: tap, enable: true) }
        monitor.onAvailabilityChange?(monitor.tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false)
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
    guard let tap else {
      onAvailabilityChange?(false)
      return
    }
    source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    onAvailabilityChange?(CGEvent.tapIsEnabled(tap: tap))
  }

  /// Sets the shortcut that events are matched against, without installing the event tap.
  func configure(definition: ShortcutDefinition, activationMode: ShortcutActivationMode) {
    self.definition = definition
    self.activationMode = activationMode
  }

  func stop() {
    let wasMonitoring = tap != nil
    if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
    if let tap { CFMachPortInvalidate(tap) }
    source = nil
    tap = nil
    definition = nil
    releaseHeldSessionOnMonitoringLoss()
    if wasMonitoring { onAvailabilityChange?(false) }
  }

  private func releaseHeldSessionOnMonitoringLoss() {
    let generation = heldLifecycleGeneration
    resetPressedState()
    if let generation { onHoldRelease?(generation) }
  }

  private func resetPressedState() {
    pressTracker.reset()
    modifierLatch.reset()
    heldLifecycleGeneration = nil
    chordWindow = nil
  }

  /// Time from the key event to now: how long the main thread took to reach the shortcut.
  /// NSEvent's timestamp shares `systemUptime`'s clock, avoiding any doubt about the units of
  /// the raw event timestamp.
  static func age(of event: CGEvent, now: TimeInterval = ProcessInfo.processInfo.systemUptime)
    -> Duration?
  {
    guard let timestamp = NSEvent(cgEvent: event)?.timestamp, timestamp > 0 else { return nil }
    let age = now - timestamp
    guard age >= 0, age < 60 else { return nil }
    return .seconds(age)
  }

  private func press(at timestamp: CGEventTimestamp, age: Duration?) {
    let lifecycleGeneration = activationMode == .hold ? onHoldPress?(age) : onPress?(age)
    heldLifecycleGeneration = activationMode == .toggle ? nil : lifecycleGeneration
    chordWindow =
      definition?.isModifierOnly == true
      ? lifecycleGeneration.map { ($0, timestamp + ShortcutPressTracker.holdThreshold) } : nil
    pressTracker.press(
      at: timestamp, finishesOnRelease: heldLifecycleGeneration != nil,
      activationMode: activationMode)
  }

  private func release(at timestamp: CGEventTimestamp) {
    let shouldFinish = pressTracker.release(at: timestamp)
    let lifecycleGeneration = heldLifecycleGeneration
    heldLifecycleGeneration = nil
    if shouldFinish, let lifecycleGeneration { onHoldRelease?(lifecycleGeneration) }
  }

  /// Returns whether the event is consumed.
  func handle(type: CGEventType, event: CGEvent) -> Bool {
    guard let definition else { return false }
    let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
    let modifierBits = definition.modifierBits(in: event.flags)
    if definition.isModifierOnly, type == .flagsChanged {
      switch modifierLatch.flagsChanged(
        current: modifierBits, required: definition.requiredModifierBits)
      {
      case .press:
        press(at: event.timestamp, age: Self.age(of: event))
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
      pressTracker.reset()
      heldLifecycleGeneration = nil
      chordWindow = nil
      // A modifier-only shortcut still held presses again only after a full release.
      modifierLatch.cancelPress()
      onCancel?()
      return true
    }
    if type == .keyDown, let window = chordWindow {
      chordWindow = nil
      // The modifier began an ordinary combination: the key goes through, and the dictation
      // the press started ends unseen. A later key never ends a dictation.
      if modifierLatch.isHeld, event.timestamp < window.ends {
        pressTracker.reset()
        heldLifecycleGeneration = nil
        onAbort?(window.lifecycleGeneration)
      }
    }
    guard !definition.isModifierOnly else { return false }
    let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
    if type == .keyDown, keyCode == definition.keyCode, !isRepeat, pressTracker.isPressed {
      // A fresh press of the key means the last press's key-up was missed, as when secure
      // input hides keys from event taps. The shortcut again is simply the next press; the
      // key alone ends the last press as its key-up would have, and goes to the app.
      if definition.matchesModifiers(event.flags) {
        pressTracker.reset()
        heldLifecycleGeneration = nil
      } else {
        release(at: event.timestamp)
      }
    }
    // The pressed key's repeats are the shortcut's until its key-up, even after its modifiers
    // are released first.
    if type == .keyDown, keyCode == definition.keyCode,
      definition.matchesModifiers(event.flags) || (isRepeat && pressTracker.isPressed)
    {
      if !isRepeat, !pressTracker.isPressed {
        press(at: event.timestamp, age: Self.age(of: event))
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

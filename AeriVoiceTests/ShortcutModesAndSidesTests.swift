import AppKit
import XCTest

@testable import AeriVoice

final class ShortcutModesAndSidesTests: XCTestCase {
  func testHoldFinishesEvenOnImmediateReleaseAndToggleNeverDoes() {
    for duration: CGEventTimestamp in [0, 1, ShortcutPressTracker.holdThreshold] {
      var hold = ShortcutPressTracker()
      hold.press(at: 100, finishesOnRelease: true, activationMode: .hold)
      XCTAssertTrue(hold.release(at: 100 + duration))
      XCTAssertFalse(hold.release(at: 100 + duration))
      var toggle = ShortcutPressTracker()
      toggle.press(at: 100, finishesOnRelease: true, activationMode: .toggle)
      XCTAssertFalse(toggle.release(at: 100 + duration))
    }
  }

  func testHybridThresholdAndRepeatPreserveOriginalPress() {
    var tracker = ShortcutPressTracker()
    tracker.press(at: 100, finishesOnRelease: true)
    tracker.press(at: 200, finishesOnRelease: true)
    XCTAssertTrue(tracker.release(at: 100 + ShortcutPressTracker.holdThreshold))
    tracker.press(at: 100, finishesOnRelease: true)
    XCTAssertFalse(tracker.release(at: 99 + ShortcutPressTracker.holdThreshold))
  }

  func testExactCommandAndOptionSidesForOrdinaryChord() {
    let definition = ShortcutDefinition(
      keyCode: 40, modifiers: UInt(CGEventFlags.maskCommand.union(.maskAlternate).rawValue),
      displayName: "L⌥R⌘K", modifierSides: [.leftOption, .rightCommand])
    let aggregate = definition.cgFlags.rawValue
    XCTAssertTrue(definition.matchesModifiers(CGEventFlags(rawValue: aggregate | 0x30)))
    XCTAssertFalse(definition.matchesModifiers(CGEventFlags(rawValue: aggregate | 0x48)))
    XCTAssertFalse(definition.matchesModifiers(CGEventFlags(rawValue: aggregate | 0x38)))
    XCTAssertFalse(definition.matchesModifiers(.maskCommand))
    let legacy = definition.removingModifierSideDistinction()
    XCTAssertFalse(legacy.distinguishesModifierSides)
    XCTAssertEqual(legacy.displayName, "⌥⌘K")
    XCTAssertTrue(legacy.matchesModifiers(CGEventFlags(rawValue: aggregate | 0x48)))
  }

  func testBothCommandSidesReleaseOnFirstSideAndWaitForFullRelease() {
    let definition = ShortcutDefinition(
      keyCode: 0, modifiers: UInt(CGEventFlags.maskCommand.rawValue),
      displayName: "L⌘R⌘", isModifierOnly: true, modifierSides: .command)
    var latch = ModifierShortcutLatch()
    func bits(_ sides: UInt64) -> UInt64 {
      definition.modifierBits(
        in: CGEventFlags(
          rawValue: sides == 0 ? 0 : CGEventFlags.maskCommand.rawValue | sides))
    }
    let required = definition.requiredModifierBits
    XCTAssertEqual(latch.flagsChanged(current: bits(0x08), required: required), .passThrough)
    XCTAssertEqual(latch.flagsChanged(current: bits(0x18), required: required), .press)
    XCTAssertEqual(latch.flagsChanged(current: bits(0x10), required: required), .release)
    XCTAssertEqual(latch.flagsChanged(current: bits(0x18), required: required), .consume)
    XCTAssertEqual(latch.flagsChanged(current: bits(0), required: required), .consume)
    XCTAssertEqual(latch.flagsChanged(current: bits(0x18), required: required), .press)
    XCTAssertEqual(definition.removingModifierSideDistinction().displayName, "⌘")
  }

  @MainActor
  func testEscapeWhileAModifierOnlyShortcutIsHeldWaitsForAFullReleaseBeforeTheNextPress() {
    let held: CGEventFlags = [.maskControl, .maskAlternate]
    let monitor = GlobalShortcutMonitor()
    monitor.configure(
      definition: ShortcutDefinition(
        keyCode: 0, modifiers: UInt(NSEvent.ModifierFlags([.control, .option]).rawValue),
        displayName: "⌃⌥", isModifierOnly: true),
      activationMode: .hold)
    var presses: [UUID] = []
    var releases: [UUID] = []
    var cancels = 0
    monitor.onHoldPress = { _ in
      presses.append(UUID())
      return presses.last
    }
    monitor.onHoldRelease = { releases.append($0) }
    monitor.onCancel = { cancels += 1 }
    monitor.shouldCancel = { true }

    XCTAssertTrue(monitor.handle(type: .flagsChanged, event: flagsEvent(held, at: 0)))
    XCTAssertTrue(monitor.handle(type: .flagsChanged, event: flagsEvent(held.union(.maskShift), at: 100)))
    XCTAssertTrue(
      monitor.handle(
        type: .keyDown, event: keyEvent(53, down: true, flags: held.union(.maskShift), at: 200)))
    // Releasing Shift, or tapping Caps Lock, with the shortcut still held.
    _ = monitor.handle(type: .flagsChanged, event: flagsEvent(held, at: 300))
    _ = monitor.handle(type: .flagsChanged, event: flagsEvent(held.union(.maskAlphaShift), at: 400))
    _ = monitor.handle(type: .flagsChanged, event: flagsEvent(held, at: 500))
    XCTAssertEqual(presses.count, 1)
    XCTAssertEqual(cancels, 1)
    XCTAssertEqual(releases, [])

    // A deliberate new press after a full release still starts.
    _ = monitor.handle(type: .flagsChanged, event: flagsEvent([], at: 600))
    XCTAssertTrue(monitor.handle(type: .flagsChanged, event: flagsEvent(held, at: 700)))
    XCTAssertEqual(presses.count, 2)
  }

  @MainActor
  func testAModifierOnlyPressThatBeginsAChordAbortsItsDictation() {
    let monitor = GlobalShortcutMonitor()
    monitor.configure(
      definition: ShortcutDefinition(
        keyCode: 0, modifiers: UInt(NSEvent.ModifierFlags.function.rawValue),
        displayName: "fn", isModifierOnly: true),
      activationMode: .hybrid)
    var presses: [UUID] = []
    var releases: [UUID] = []
    var aborts: [UUID] = []
    monitor.onPress = { _ in
      presses.append(UUID())
      return presses.last
    }
    monitor.onHoldRelease = { releases.append($0) }
    monitor.onAbort = { aborts.append($0) }

    // A bare tap is a press, and nothing is aborted.
    XCTAssertTrue(monitor.handle(type: .flagsChanged, event: flagsEvent(.maskSecondaryFn, at: 1_000)))
    XCTAssertTrue(monitor.handle(type: .flagsChanged, event: flagsEvent([], at: 1_120)))
    XCTAssertEqual(presses.count, 1)
    XCTAssertEqual(aborts, [])

    // fn-Delete (forward delete) reaches the app and aborts the dictation fn started; the
    // release after the hold threshold finishes nothing.
    XCTAssertTrue(monitor.handle(type: .flagsChanged, event: flagsEvent(.maskSecondaryFn, at: 2_000)))
    XCTAssertFalse(
      monitor.handle(type: .keyDown, event: keyEvent(117, down: true, flags: .maskSecondaryFn, at: 2_050)))
    XCTAssertFalse(
      monitor.handle(type: .keyUp, event: keyEvent(117, down: false, flags: .maskSecondaryFn, at: 2_100)))
    _ = monitor.handle(type: .flagsChanged, event: flagsEvent([], at: 2_400))
    XCTAssertEqual(presses.count, 2)
    XCTAssertEqual(aborts, [presses[1]])
    XCTAssertEqual(releases, [])

    // A key pressed after the threshold never ends a dictation held longer.
    XCTAssertTrue(monitor.handle(type: .flagsChanged, event: flagsEvent(.maskSecondaryFn, at: 3_000)))
    XCTAssertFalse(
      monitor.handle(type: .keyDown, event: keyEvent(117, down: true, flags: .maskSecondaryFn, at: 3_400)))
    _ = monitor.handle(type: .flagsChanged, event: flagsEvent([], at: 3_600))
    XCTAssertEqual(presses.count, 3)
    XCTAssertEqual(aborts, [presses[1]])
    XCTAssertEqual(releases, [presses[2]])

    // A key after a quick tap is not a chord: the tap's hands-free dictation goes on.
    XCTAssertTrue(monitor.handle(type: .flagsChanged, event: flagsEvent(.maskSecondaryFn, at: 4_000)))
    _ = monitor.handle(type: .flagsChanged, event: flagsEvent([], at: 4_100))
    XCTAssertFalse(monitor.handle(type: .keyDown, event: keyEvent(0, down: true, flags: [], at: 4_200)))
    XCTAssertEqual(presses.count, 4)
    XCTAssertEqual(aborts, [presses[1]])
  }

  @MainActor
  func testAKeyedShortcutOwnsItsKeyRepeatsUntilKeyUpWhenItsModifierIsReleasedFirst() {
    for mode in [ShortcutActivationMode.hold, .hybrid] {
      let monitor = GlobalShortcutMonitor()
      monitor.configure(
        definition: ShortcutDefinition(
          keyCode: 49, modifiers: UInt(NSEvent.ModifierFlags.control.rawValue),
          displayName: "⌃Space"),
        activationMode: mode)
      var presses: [UUID] = []
      var releases: [UUID] = []
      let press: (Duration?) -> UUID? = { _ in
        presses.append(UUID())
        return presses.last
      }
      monitor.onHoldPress = press
      monitor.onPress = press
      monitor.onHoldRelease = { releases.append($0) }

      XCTAssertTrue(
        monitor.handle(type: .keyDown, event: keyEvent(49, down: true, flags: .maskControl, at: 0)),
        "\(mode)")
      // Control goes up first; Space is still held and repeats.
      XCTAssertFalse(monitor.handle(type: .flagsChanged, event: flagsEvent([], at: 100)), "\(mode)")
      for repeatAt: UInt64 in [500, 533] {
        XCTAssertTrue(
          monitor.handle(
            type: .keyDown, event: keyEvent(49, down: true, flags: [], at: repeatAt, autorepeat: 1)),
          "\(mode) repeat at \(repeatAt)")
      }
      XCTAssertTrue(
        monitor.handle(type: .keyUp, event: keyEvent(49, down: false, flags: [], at: 600)), "\(mode)")
      // Ownership ends at key-up: Space typed afterwards goes through.
      XCTAssertFalse(
        monitor.handle(
          type: .keyDown, event: keyEvent(49, down: true, flags: [], at: 700, autorepeat: 1)),
        "\(mode)")
      XCTAssertFalse(
        monitor.handle(type: .keyDown, event: keyEvent(49, down: true, flags: [], at: 800)), "\(mode)")
      XCTAssertEqual(presses.count, 1, "\(mode)")
      XCTAssertEqual(releases, presses, "\(mode)")
    }
  }

  @MainActor
  func testAFreshPressOfTheShortcutKeyEndsAPressWhoseKeyUpWasMissed() {
    for mode in [ShortcutActivationMode.hold, .hybrid, .toggle] {
      for again in ["key alone", "shortcut"] {
        let monitor = GlobalShortcutMonitor()
        monitor.configure(
          definition: ShortcutDefinition(
            keyCode: 49, modifiers: UInt(NSEvent.ModifierFlags.control.rawValue),
            displayName: "⌃Space"),
          activationMode: mode)
        var presses: [UUID] = []
        var releases: [UUID] = []
        let press: (Duration?) -> UUID? = { _ in
          presses.append(UUID())
          return presses.last
        }
        monitor.onHoldPress = press
        monitor.onPress = press
        monitor.onHoldRelease = { releases.append($0) }
        let label = "\(mode), then the \(again)"

        XCTAssertTrue(
          monitor.handle(type: .keyDown, event: keyEvent(49, down: true, flags: .maskControl, at: 0)),
          label)
        // Its key-up never arrives, as while secure input hides keys from event taps.
        if again == "key alone" {
          // A plain Space goes to the app, repeats and all; the missed release ends the press.
          XCTAssertFalse(
            monitor.handle(type: .keyDown, event: keyEvent(49, down: true, flags: [], at: 1_000)),
            label)
          XCTAssertFalse(
            monitor.handle(
              type: .keyDown, event: keyEvent(49, down: true, flags: [], at: 1_500, autorepeat: 1)),
            label)
          XCTAssertFalse(
            monitor.handle(type: .keyUp, event: keyEvent(49, down: false, flags: [], at: 1_600)),
            label)
          XCTAssertEqual(presses.count, 1, label)
          XCTAssertEqual(releases, mode == .toggle ? [] : presses, label)
        } else {
          // The shortcut again is the next press, as usual.
          XCTAssertTrue(
            monitor.handle(
              type: .keyDown, event: keyEvent(49, down: true, flags: .maskControl, at: 1_000)),
            label)
          XCTAssertTrue(
            monitor.handle(type: .keyUp, event: keyEvent(49, down: false, flags: [], at: 1_500)),
            label)
          XCTAssertEqual(presses.count, 2, label)
          XCTAssertEqual(releases, mode == .toggle ? [] : Array(presses.dropFirst()), label)
        }
      }
    }
  }

  /// Event times are in nanoseconds; `ms` keeps the tests readable.
  private func flagsEvent(_ flags: CGEventFlags, at ms: UInt64) -> CGEvent {
    let event = CGEvent(source: nil)!
    event.type = .flagsChanged
    event.flags = flags
    event.timestamp = ms * 1_000_000
    return event
  }

  private func keyEvent(
    _ keyCode: CGKeyCode, down: Bool, flags: CGEventFlags, at ms: UInt64, autorepeat: Int64 = 0
  ) -> CGEvent {
    let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: down)!
    event.flags = flags
    event.timestamp = ms * 1_000_000
    event.setIntegerValueField(.keyboardEventAutorepeat, value: autorepeat)
    return event
  }

  func testLegacyDecodeAndSideMetadataRoundTrip() throws {
    let old = Data(#"{"keyCode":40,"modifiers":1048576,"displayName":"⌘K"}"#.utf8)
    let legacy = try JSONDecoder().decode(ShortcutDefinition.self, from: old)
    XCTAssertFalse(legacy.distinguishesModifierSides)
    XCTAssertFalse(legacy.isModifierOnly)
    let sided = ShortcutDefinition(
      keyCode: 40, modifiers: legacy.modifiers, displayName: "R⌘K",
      modifierSides: .rightCommand)
    XCTAssertEqual(
      try JSONDecoder().decode(ShortcutDefinition.self, from: JSONEncoder().encode(sided)), sided)
  }
}

@MainActor
final class ShortcutCaptureLifecycleTests: XCTestCase {
  func testCancelClearsPendingSidesAndDoesNotCommit() {
    let recorder = ShortcutRecorderNSView()
    recorder.distinguishModifierSides = true
    var events: [String] = []
    recorder.onCaptureStart = { events.append("start") }
    recorder.onCaptureCancel = { events.append("cancel") }
    recorder.onCaptureEnd = { events.append("end") }
    recorder.onCapture = { _ in events.append("capture") }
    recorder.beginCapture()
    recorder.captureModifierFlags(
      NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.command.rawValue | 0x08))
    recorder.cancelCapture()
    recorder.cancelCapture()
    XCTAssertEqual(events, ["start", "cancel", "end"])
    XCTAssertFalse(recorder.isCapturing)
    recorder.beginCapture()
    recorder.captureModifierFlags([])
    XCTAssertEqual(events, ["start", "cancel", "end", "start"])
  }

  func testEscapeCancelsCaptureWithoutCommitting() throws {
    let recorder = ShortcutRecorderNSView()
    var cancels = 0
    var captures = 0
    recorder.onCaptureCancel = { cancels += 1 }
    recorder.onCapture = { _ in captures += 1 }
    recorder.beginCapture()
    let escape = try XCTUnwrap(
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
        windowNumber: 0, context: nil, characters: "\u{1b}",
        charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
    recorder.keyDown(with: escape)
    XCTAssertEqual(cancels, 1)
    XCTAssertEqual(captures, 0)
    XCTAssertFalse(recorder.isCapturing)
  }

  func testOrdinaryChordCapturesExactSideAndIgnoresRepeat() throws {
    let recorder = ShortcutRecorderNSView()
    recorder.distinguishModifierSides = true
    var captured: [ShortcutDefinition] = []
    recorder.onCapture = { captured.append($0) }
    recorder.beginCapture()
    for isRepeat in [true, false] {
      let key = try XCTUnwrap(
        NSEvent.keyEvent(
          with: .keyDown, location: .zero,
          modifierFlags: NSEvent.ModifierFlags(
            rawValue: NSEvent.ModifierFlags.command.rawValue | 0x10),
          timestamp: 0, windowNumber: 0, context: nil, characters: "k",
          charactersIgnoringModifiers: "k", isARepeat: isRepeat, keyCode: 40))
      recorder.keyDown(with: key)
      XCTAssertEqual(captured.count, isRepeat ? 0 : 1)
    }
    XCTAssertEqual(captured.first?.modifierSides, .rightCommand)
    XCTAssertEqual(captured.first?.displayName, "R⌘K")
    XCTAssertEqual(captured.first?.isModifierOnly, false)
  }

  func testSideCaptureCommitsBothSidesAndCompletesLifecycleOnce() {
    let recorder = ShortcutRecorderNSView()
    recorder.distinguishModifierSides = true
    var definition: ShortcutDefinition?
    var ends = 0
    var cancels = 0
    recorder.onCapture = { definition = $0 }
    recorder.onCaptureEnd = { ends += 1 }
    recorder.onCaptureCancel = { cancels += 1 }
    recorder.beginCapture()
    recorder.captureModifierFlags(
      NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.option.rawValue | 0x60))
    recorder.captureModifierFlags(
      NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.option.rawValue | 0x20))
    recorder.captureModifierFlags([])
    _ = recorder.resignFirstResponder()
    XCTAssertEqual(definition?.modifierSides, .option)
    XCTAssertEqual(definition?.displayName, "L⌥R⌥")
    XCTAssertEqual(ends, 1)
    XCTAssertEqual(cancels, 0)
  }
}

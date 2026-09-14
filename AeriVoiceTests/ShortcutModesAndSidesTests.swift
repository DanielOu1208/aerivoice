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

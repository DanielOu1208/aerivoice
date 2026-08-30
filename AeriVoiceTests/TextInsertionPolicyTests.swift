import ApplicationServices
import XCTest

@testable import AeriVoice

final class TextInsertionPolicyTests: XCTestCase {
  func testNativeTextFieldUsesEnabledPasteCommand() {
    let traits = TextTargetTraits(
      roles: [kAXTextFieldRole as String],
      supportedAttributes: [kAXSelectedTextAttribute as String],
      settableAttributes: [kAXValueAttribute as String])

    XCTAssertTrue(TextTargetPolicy.isEditable(traits))
    XCTAssertEqual(
      TextTargetPolicy.dispatchStrategy(for: traits, hasEnabledPasteCommand: true),
      .menuCommand)
  }

  func testElectronStyleEditableGroupUsesEnabledPasteCommand() {
    let traits = TextTargetTraits(
      roles: [kAXGroupRole as String],
      supportedAttributes: [
        kAXSelectedTextAttribute as String,
        kAXSelectedTextRangeAttribute as String,
        kAXNumberOfCharactersAttribute as String,
      ])

    XCTAssertTrue(TextTargetPolicy.isEditable(traits))
    XCTAssertEqual(
      TextTargetPolicy.dispatchStrategy(for: traits, hasEnabledPasteCommand: true),
      .menuCommand)
  }

  func testSecureAncestorAlwaysCopies() {
    let traits = TextTargetTraits(
      roles: [kAXTextFieldRole as String],
      subroles: [kAXSecureTextFieldSubrole as String],
      settableAttributes: [kAXValueAttribute as String])

    XCTAssertTrue(TextTargetPolicy.isSecure(traits))
    XCTAssertEqual(
      TextTargetPolicy.dispatchStrategy(for: traits, hasEnabledPasteCommand: true),
      .copyOnly)
  }

  func testUnverifiedGroupCopiesEvenWhenAppHasPasteCommand() {
    let traits = TextTargetTraits(roles: [kAXGroupRole as String])

    XCTAssertFalse(TextTargetPolicy.isEditable(traits))
    XCTAssertEqual(
      TextTargetPolicy.dispatchStrategy(for: traits, hasEnabledPasteCommand: true),
      .copyOnly)
  }

  func testStrongEditableTargetWithoutMenuUsesTargetedShortcut() {
    let traits = TextTargetTraits(
      roles: [kAXGroupRole as String],
      settableAttributes: [kAXSelectedTextAttribute as String])

    XCTAssertEqual(
      TextTargetPolicy.dispatchStrategy(for: traits, hasEnabledPasteCommand: false),
      .targetedShortcut)
  }

  func testKnownTextAreaWithoutMenuUsesTargetedShortcut() {
    let traits = TextTargetTraits(
      roles: [kAXTextAreaRole as String],
      supportedAttributes: [kAXSelectedTextRangeAttribute as String])

    XCTAssertEqual(
      TextTargetPolicy.dispatchStrategy(for: traits, hasEnabledPasteCommand: false),
      .targetedShortcut)
  }

  func testEvidenceFromDifferentElementsDoesNotCreateAnEditor() {
    let roleOnly = TextTargetTraits(roles: [kAXGroupRole as String])
    let rangeOnly = TextTargetTraits(
      supportedAttributes: [kAXSelectedTextRangeAttribute as String])
    let selectionOnly = TextTargetTraits(
      supportedAttributes: [
        kAXSelectedTextAttribute as String,
        kAXNumberOfCharactersAttribute as String,
      ])

    XCTAssertFalse(TextTargetPolicy.isEditable(roleOnly))
    XCTAssertFalse(TextTargetPolicy.isEditable(rangeOnly))
    XCTAssertFalse(TextTargetPolicy.isEditable(selectionOnly))
  }

  func testStandardPasteMenuMatchesCommandV() {
    XCTAssertTrue(
      PasteMenuItemPolicy.isStandardPaste(
        PasteMenuItemTraits(
          commandCharacter: "V", virtualKey: nil, modifiers: 0, enabled: true)))
    XCTAssertTrue(
      PasteMenuItemPolicy.isStandardPaste(
        PasteMenuItemTraits(
          commandCharacter: nil, virtualKey: 9, modifiers: 0, enabled: true)))
  }

  func testStandardPasteMenuRejectsDisabledOrModifiedVariants() {
    XCTAssertFalse(
      PasteMenuItemPolicy.isStandardPaste(
        PasteMenuItemTraits(
          commandCharacter: "V", virtualKey: 9, modifiers: 0, enabled: false)))
    XCTAssertFalse(
      PasteMenuItemPolicy.isStandardPaste(
        PasteMenuItemTraits(
          commandCharacter: "V", virtualKey: 9, modifiers: 1, enabled: true)))
    XCTAssertFalse(
      PasteMenuItemPolicy.isStandardPaste(
        PasteMenuItemTraits(
          commandCharacter: "V", virtualKey: 9, modifiers: nil, enabled: true)))
  }

  func testTargetedPasteEventsCarryCommandVAndSyntheticMarker() throws {
    let events = try XCTUnwrap(TargetedPasteEvent.makePair())

    for event in [events.down, events.up] {
      XCTAssertEqual(event.getIntegerValueField(.keyboardEventKeycode), 9)
      XCTAssertTrue(event.flags.contains(.maskCommand))
      XCTAssertEqual(
        event.getIntegerValueField(.eventSourceUserData), TargetedPasteEvent.marker)
    }
  }

  func testDispatcherRunsOnlyTheSelectedAction() {
    var menuCount = 0
    var shortcutCount = 0

    XCTAssertTrue(
      PasteActionDispatcher.dispatch(
        strategy: .targetedShortcut,
        targetIsCurrent: { true },
        pressMenuItem: {
          menuCount += 1
          return true
        },
        postTargetedShortcut: {
          shortcutCount += 1
          return true
        },
        isCancelled: { false }))

    XCTAssertEqual(menuCount, 0)
    XCTAssertEqual(shortcutCount, 1)
  }

  func testDispatcherDoesNotActWhenCancellationArrivesDuringTargetValidation() {
    var cancelled = false
    var dispatchCount = 0

    XCTAssertFalse(
      PasteActionDispatcher.dispatch(
        strategy: .targetedShortcut,
        targetIsCurrent: {
          cancelled = true
          return true
        },
        pressMenuItem: {
          dispatchCount += 1
          return true
        },
        postTargetedShortcut: {
          dispatchCount += 1
          return true
        },
        isCancelled: { cancelled }))

    XCTAssertEqual(dispatchCount, 0)
  }
}

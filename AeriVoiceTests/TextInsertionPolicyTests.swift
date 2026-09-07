import ApplicationServices
import XCTest

@testable import AeriVoice

final class TextInsertionPolicyTests: XCTestCase {
  func testExistingFocusDoesNotRequestAccessibilityOrWait() async {
    let focus = await FocusedElementRecovery.resolve(
      targetIsCurrent: { true }, readFocus: { 42 },
      requestAccessibility: {
        XCTFail("Existing focus needs no activation")
        return false
      },
      wait: { XCTFail("Existing focus needs no delay") })
    XCTAssertEqual(focus, 42)
  }

  func testFocusCanAppearAfterAccessibilityActivation() async {
    var activated = false
    var waits = 0
    let focus = await FocusedElementRecovery.resolve(
      targetIsCurrent: { true }, readFocus: { activated && waits == 2 ? 42 : nil },
      requestAccessibility: {
        activated = true
        return true
      },
      wait: { waits += 1 })
    XCTAssertEqual(focus, 42)
    XCTAssertEqual(waits, 2)
  }

  func testUnavailableFocusStopsAfterThreeRetries() async {
    var waits = 0
    let focus: Int? = await FocusedElementRecovery.resolve(
      targetIsCurrent: { true }, readFocus: { nil }, requestAccessibility: { true },
      wait: { waits += 1 })
    XCTAssertNil(focus)
    XCTAssertEqual(waits, 3)
  }

  func testUnsupportedAccessibilityDoesNotRetryFocus() async {
    let focus: Int? = await FocusedElementRecovery.resolve(
      targetIsCurrent: { true }, readFocus: { nil }, requestAccessibility: { false },
      wait: { XCTFail("Unsupported activation should copy immediately") })
    XCTAssertNil(focus)
  }

  func testAppSwitchDuringRecoveryRejectsNewFocus() async {
    var current = true
    var reads = 0
    let focus = await FocusedElementRecovery.resolve(
      targetIsCurrent: { current },
      readFocus: {
        reads += 1
        return reads > 1 ? 42 : nil
      },
      requestAccessibility: { true }, wait: { current = false })
    XCTAssertNil(focus)
    XCTAssertEqual(reads, 1)
  }

  func testCancellationDuringRecoveryRejectsNewFocus() async {
    var cancelled = false
    var reads = 0
    let focus = await FocusedElementRecovery.resolve(
      targetIsCurrent: { true },
      readFocus: {
        reads += 1
        return reads > 1 ? 42 : nil
      },
      requestAccessibility: { true }, wait: { cancelled = true },
      isCancelled: { cancelled })
    XCTAssertNil(focus)
    XCTAssertEqual(reads, 1)
  }

  func testCancelledWaitStopsRecovery() async {
    let focus: Int? = await FocusedElementRecovery.resolve(
      targetIsCurrent: { true }, readFocus: { nil }, requestAccessibility: { true },
      wait: { throw CancellationError() })
    XCTAssertNil(focus)
  }

  func testExistingButUnusableFocusRequestsAccessibility() async {
    var activated = false
    let focus = await FocusedElementRecovery.resolve(
      targetIsCurrent: { true }, readFocus: { 42 },
      requestAccessibility: {
        activated = true
        return true
      },
      isUsable: { _ in activated }, wait: {})
    XCTAssertEqual(focus, 42)
    XCTAssertTrue(activated)
  }

  func testDelayedActivationUsesConfiguredBound() async {
    var waits = 0
    let focus: Int? = await FocusedElementRecovery.resolve(
      targetIsCurrent: { true }, readFocus: { 42 }, requestAccessibility: { true },
      isUsable: { _ in waits >= 9 }, attempts: 12, wait: { waits += 1 })
    XCTAssertEqual(focus, 42)
    XCTAssertEqual(waits, 9)
  }

  func testExplicitReadOnlyOrDisabledOverridesMutableAttributes() {
    var traits = TextTargetTraits(
      roles: [kAXTextFieldRole as String],
      settableAttributes: [kAXSelectedTextAttribute as String],
      secureTextStatus: .nonSecure, enabled: false)
    XCTAssertFalse(TextTargetPolicy.isEditable(traits))
    traits.enabled = true
    traits.editable = false
    XCTAssertFalse(TextTargetPolicy.isEditable(traits))
  }

  func testSelectionAttributesAloneAreNotMutabilityEvidence() {
    let traits = TextTargetTraits(
      roles: [kAXGroupRole as String],
      supportedAttributes: [
        kAXSelectedTextAttribute as String,
        kAXSelectedTextRangeAttribute as String, kAXNumberOfCharactersAttribute as String,
      ],
      secureTextStatus: .nonSecure)
    XCTAssertFalse(TextTargetPolicy.isEditable(traits))
  }

  func testNativeTextFieldUsesEnabledPasteCommand() {
    let traits = TextTargetTraits(
      roles: [kAXTextFieldRole as String],
      supportedAttributes: [kAXSelectedTextAttribute as String],
      settableAttributes: [kAXValueAttribute as String],
      secureTextStatus: .nonSecure)

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
      ],
      secureTextStatus: .nonSecure, editable: true)

    XCTAssertTrue(TextTargetPolicy.isEditable(traits))
    XCTAssertEqual(
      TextTargetPolicy.dispatchStrategy(for: traits, hasEnabledPasteCommand: true),
      .menuCommand)
  }

  func testSecureAncestorAlwaysCopies() {
    let traits = TextTargetTraits(
      roles: [kAXTextFieldRole as String],
      settableAttributes: [kAXValueAttribute as String],
      secureTextStatus: .secure)

    XCTAssertFalse(TextTargetPolicy.permitsInsertion(traits))
    XCTAssertEqual(
      TextTargetPolicy.dispatchStrategy(for: traits, hasEnabledPasteCommand: true),
      .copyOnly)
  }

  func testUnverifiedGroupCopiesEvenWhenAppHasPasteCommand() {
    let traits = TextTargetTraits(
      roles: [kAXGroupRole as String], secureTextStatus: .nonSecure)

    XCTAssertFalse(TextTargetPolicy.isEditable(traits))
    XCTAssertEqual(
      TextTargetPolicy.dispatchStrategy(for: traits, hasEnabledPasteCommand: true),
      .copyOnly)
  }

  func testStrongEditableTargetWithoutMenuUsesTargetedShortcut() {
    let traits = TextTargetTraits(
      roles: [kAXGroupRole as String],
      settableAttributes: [kAXSelectedTextAttribute as String],
      secureTextStatus: .nonSecure)

    XCTAssertEqual(
      TextTargetPolicy.dispatchStrategy(for: traits, hasEnabledPasteCommand: false),
      .targetedShortcut)
  }

  func testReadOnlyTextAreaWithoutMenuCopies() {
    let traits = TextTargetTraits(
      roles: [kAXTextAreaRole as String],
      supportedAttributes: [kAXSelectedTextRangeAttribute as String],
      secureTextStatus: .nonSecure)

    XCTAssertEqual(
      TextTargetPolicy.dispatchStrategy(for: traits, hasEnabledPasteCommand: false),
      .copyOnly)
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

  func testUnknownSecureStatusAlwaysCopies() {
    let traits = TextTargetTraits(
      roles: [kAXTextFieldRole as String],
      settableAttributes: [kAXValueAttribute as String])

    XCTAssertEqual(traits.secureTextStatus, .unknown)
    XCTAssertFalse(TextTargetPolicy.permitsInsertion(traits))
    XCTAssertEqual(
      TextTargetPolicy.dispatchStrategy(for: traits, hasEnabledPasteCommand: true),
      .copyOnly)
  }

  func testSecureStatusMapsAccessibilityOutcomesConservatively() {
    XCTAssertEqual(
      SecureTextStatus.resolve(
        subrole: kAXSecureTextFieldSubrole as String, result: .success),
      .secure)
    XCTAssertEqual(
      SecureTextStatus.resolve(subrole: "AXStandardTextField", result: .success),
      .nonSecure)
    XCTAssertEqual(
      SecureTextStatus.resolve(subrole: nil, result: .attributeUnsupported),
      .nonSecure)
    XCTAssertEqual(SecureTextStatus.resolve(subrole: nil, result: .noValue), .nonSecure)
    XCTAssertEqual(SecureTextStatus.resolve(subrole: nil, result: .success), .unknown)
    XCTAssertEqual(
      SecureTextStatus.resolve(subrole: nil, result: .cannotComplete), .unknown)
    XCTAssertEqual(SecureTextStatus.resolve(subrole: nil, result: .failure), .unknown)
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

}

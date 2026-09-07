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

  func testStandardTextRolesAcceptPasteWithoutAXMutationSupport() {
    for role in [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole] {
      XCTAssertTrue(
        TextTargetPolicy.isTextTarget(
          TextTargetTraits(roles: [role as String], secureTextStatus: .nonSecure)))
    }
  }

  func testExplicitReadOnlyDisabledSecureOrUnknownAlwaysRejects() {
    var traits = TextTargetTraits(roles: [kAXTextAreaRole as String], secureTextStatus: .nonSecure)
    traits.editable = false
    XCTAssertFalse(TextTargetPolicy.isTextTarget(traits))
    traits.editable = true
    traits.enabled = false
    XCTAssertFalse(TextTargetPolicy.isTextTarget(traits))
    traits.enabled = true
    for status in [SecureTextStatus.secure, .unknown] {
      traits.secureTextStatus = status
      XCTAssertFalse(TextTargetPolicy.isTextTarget(traits))
    }
  }

  func testCustomEditorNeedsEditableFlagAndSelectionMetadataTogether() {
    var traits = TextTargetTraits(roles: [kAXGroupRole as String], secureTextStatus: .nonSecure)
    traits.supportedAttributes = [
      kAXSelectedTextAttribute as String, kAXSelectedTextRangeAttribute as String,
    ]
    XCTAssertFalse(TextTargetPolicy.isTextTarget(traits))
    traits.editable = true
    XCTAssertTrue(TextTargetPolicy.isTextTarget(traits))
    traits.supportedAttributes.remove(kAXSelectedTextRangeAttribute as String)
    XCTAssertFalse(TextTargetPolicy.isTextTarget(traits))
  }

  func testDefinitePolicyRejectionDoesNotActivateOrRetryAccessibility() async {
    let result: Result<Int, PasteBlockReason>? = await FocusedElementRecovery.resolve(
      targetIsCurrent: { true }, readFocus: { .failure(.secureField) },
      requestAccessibility: {
        XCTFail("Secure target must not trigger recovery")
        return true
      },
      wait: { XCTFail("Secure target must not be retried") })
    XCTAssertEqual(result, .failure(.secureField))
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

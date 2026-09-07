import ApplicationServices
import XCTest

@testable import AeriVoice

final class InsertionSafetyTests: XCTestCase {
  func testDeadlineCapsEveryQueryAndExpiresAcrossStages() {
    var now = 10.0
    let deadline = InsertionDeadline(seconds: 0.75, now: { now })
    XCTAssertEqual(deadline.timeout(), 0.1)
    now = 10.7
    XCTAssertEqual(deadline.timeout() ?? 0, 0.05, accuracy: 0.0001)
    now = 10.75
    XCTAssertTrue(deadline.isExpired)
    XCTAssertNil(deadline.timeout())
  }

  func testRecoveryDelayIsCappedByRemainingBudget() {
    var now = 0.0
    let deadline = InsertionDeadline(seconds: 3.25, now: { now })
    XCTAssertEqual(deadline.remainingDelay(maximum: 0.25), 0.25)
    now = 3.2
    XCTAssertEqual(deadline.remainingDelay(maximum: 0.25) ?? 0, 0.05, accuracy: 0.0001)
    now = 3.25
    XCTAssertNil(deadline.remainingDelay(maximum: 0.25))
  }

  func testAXQueryDoesNotRunWhenTimeoutSetupFails() {
    let response: (AXError, Int?) = AXQuery.read {
      false
    } perform: {
      XCTFail("Cannot issue an AX read without a timeout")
      return (.success, 42)
    }
    XCTAssertEqual(response.0, .cannotComplete)
    XCTAssertNil(response.1)
  }

  func testAXQueryRefreshesTimeoutBeforeRetryAndStopsOnExpiredBudget() {
    var timeouts = 0
    var reads = 0
    let response: (AXError, Int?) = AXQuery.read {
      timeouts += 1
      return timeouts == 1
    } perform: {
      reads += 1
      return (.cannotComplete, nil)
    }
    XCTAssertEqual(timeouts, 2)
    XCTAssertEqual(reads, 1)
    XCTAssertEqual(response.0, .cannotComplete)
  }

  func testAXQueryRetryIsBoundedAndDoesNotRetryUnsupportedAttributes() {
    var reads = 0
    let _: (AXError, Int?) = AXQuery.read {
      true
    } perform: {
      reads += 1
      return (.cannotComplete, nil)
    }
    XCTAssertEqual(reads, 2)
    reads = 0
    let _: (AXError, Int?) = AXQuery.read {
      true
    } perform: {
      reads += 1
      return (.attributeUnsupported, nil)
    }
    XCTAssertEqual(reads, 1)
  }

  func testAXMutationSeparatesAcceptedRejectedAndAmbiguousResults() {
    XCTAssertEqual(AXMutationOutcome.resolve(.success, success: .pasteRequested), .pasteRequested)
    XCTAssertEqual(AXMutationOutcome.resolve(.success, success: .inserted), .inserted)
    for result in [
      AXError.actionUnsupported, .attributeUnsupported, .invalidUIElement,
      .illegalArgument, .apiDisabled, .notImplemented,
    ] {
      XCTAssertEqual(AXMutationOutcome.resolve(result, success: .pasteRequested), .unavailable)
    }
    XCTAssertEqual(AXMutationOutcome.resolve(.cannotComplete, success: .pasteRequested), .uncertain)
    XCTAssertEqual(AXMutationOutcome.resolve(.failure, success: .inserted), .uncertain)
  }

  func testCompleteAncestryReturnsEditor() {
    XCTAssertEqual(resolve(parents: [.parent(1), .root]), 0)
  }

  func testMissingParentAfterEditorIsNotARoot() {
    XCTAssertNil(resolve(parents: [.parent(1), .unavailable]))
  }

  func testSecureAncestorRejectsEditor() {
    XCTAssertNil(resolve(parents: [.parent(1), .root], secureIndex: 1))
  }

  func testUnknownAncestorRejectsEditor() {
    XCTAssertNil(resolve(parents: [.parent(1), .root], unknownIndex: 1))
  }

  func testDepthLimitAndCyclesRejectEditor() {
    XCTAssertNil(resolve(parents: [.parent(1), .root], maximumDepth: 1))
    XCTAssertNil(resolve(parents: [.parent(1), .parent(0)]))
    XCTAssertNil(resolve(parents: [.parent(0)]))
  }

  func testDeepSecureAncestorIsNotSkipped() {
    let parents: [ParentLookup<Int>] = (1...12).map { .parent($0) } + [.root]
    XCTAssertNil(resolve(parents: parents, secureIndex: 12))
  }

  func testCancellationStopsBeforeReadingTraits() {
    let editor: Int? = EditorAncestry.resolve(
      startingAt: 0,
      traits: { _ in
        XCTFail("Cancelled walk must not query AX")
        return TextTargetTraits()
      },
      parent: { _ in .root }, same: ==, shouldStop: { true })
    XCTAssertNil(editor)
  }

  private func resolve(
    parents: [ParentLookup<Int>], secureIndex: Int? = nil, unknownIndex: Int? = nil,
    maximumDepth: Int = 32
  ) -> Int? {
    EditorAncestry.resolve(
      startingAt: 0, maximumDepth: maximumDepth,
      traits: { index in
        TextTargetTraits(
          roles: [kAXTextFieldRole as String],
          settableAttributes: index == 0 ? [kAXValueAttribute as String] : [],
          secureTextStatus: index == secureIndex
            ? .secure : index == unknownIndex ? .unknown : .nonSecure)
      },
      parent: { parents[$0] }, same: ==, shouldStop: { false })
  }
}

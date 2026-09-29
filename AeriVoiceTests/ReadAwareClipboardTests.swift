import AppKit
import XCTest

@testable import AeriVoice

@MainActor
final class ReadAwareClipboardTests: XCTestCase {
  func testReadAfterDispatchRestoresOriginalWithoutEditorReadback() async throws {
    let fixture = ReadFixture()
    defer { fixture.close() }
    let target = await fixture.service.captureTarget().value
    let result = await fixture.insert(target)
    XCTAssertEqual(result, .pasteSent)
    XCTAssertEqual(fixture.board.string(forType: .string), "transcript")
    await fixture.service.finishPendingRestoration()
    XCTAssertEqual(fixture.outcomes, [.restoredAfterRead])
    XCTAssertEqual(fixture.board.string(forType: .string), "original")
  }

  // This is an adversarial characterization, not a successful-paste test.
  // Keep the fallback candidate-only until a destination-specific signal exists.
  func testUnrelatedReaderReproducesPrototypePromotionBlocker() async {
    let fixture = ReadFixture()
    defer { fixture.close() }
    let target = await fixture.service.captureTarget().value
    _ = await fixture.insert(target)
    // A clipboard manager reads, while the intended destination has not read yet.
    let unrelatedReaderSaw = fixture.board.string(forType: .string)
    XCTAssertEqual(unrelatedReaderSaw, "transcript")
    await fixture.service.finishPendingRestoration()
    XCTAssertEqual(fixture.outcomes, [.restoredAfterRead])
    // The delayed destination now receives the wrong value. The data-provider
    // callback has no reader identity, so ownership guards cannot distinguish it.
    let delayedDestinationSaw = fixture.board.string(forType: .string)
    XCTAssertEqual(delayedDestinationSaw, "original")
    XCTAssertNotEqual(delayedDestinationSaw, "transcript")
  }

  func testNoReadLeavesMaterializedTranscriptAfterProviderIsReleased() async {
    let fixture = ReadFixture()
    defer { fixture.close() }
    let target = await fixture.service.captureTarget().value
    _ = await fixture.insert(target)
    let deadline = ContinuousClock.now.advanced(by: .seconds(1))
    while fixture.outcomes.isEmpty, ContinuousClock.now < deadline {
      try? await Task.sleep(for: .milliseconds(2))
    }
    XCTAssertEqual(fixture.outcomes, [.noEligibleRead])
    XCTAssertEqual(fixture.board.string(forType: .string), "transcript")
  }

  func testUserCopyDuringGraceWinsEvenWhenItsTextMatchesTranscript() async {
    for copy in ["new copy", "transcript"] {
      let fixture = ReadFixture()
      defer { fixture.close() }
      let target = await fixture.service.captureTarget().value
      _ = await fixture.insert(target)
      _ = fixture.board.string(forType: .string)
      fixture.board.clearContents()
      fixture.board.setString(copy, forType: .string)
      await fixture.service.finishPendingRestoration()
      XCTAssertEqual(fixture.outcomes, [.superseded])
      XCTAssertEqual(fixture.board.string(forType: .string), copy)
    }
  }

  func testCancellationMaterializesPromiseAndNeverRestores() async {
    let fixture = ReadFixture()
    defer { fixture.close() }
    let target = await fixture.service.captureTarget().value
    _ = await fixture.insert(target)
    fixture.service.invalidatePendingRestoration()
    XCTAssertEqual(fixture.outcomes, [.cancelled])
    XCTAssertEqual(fixture.board.string(forType: .string), "transcript")
  }

  func testFailedDispatchKeepsTranscriptForManualPaste() async {
    let fixture = ReadFixture()
    defer { fixture.close() }
    fixture.dispatchResult = .blocked(.shortcutUnavailable)
    let target = await fixture.service.captureTarget().value
    let result = await fixture.insert(target)
    XCTAssertEqual(result, .copied(.shortcutUnavailable))
    XCTAssertEqual(fixture.board.string(forType: .string), "transcript")
    XCTAssertFalse(fixture.outcomes.contains(.restoredAfterRead))
  }

  func testOverlappingDictationsCarryOriginalBackup() async {
    let fixture = ReadFixture()
    defer { fixture.close() }
    let first = await fixture.service.captureTarget().value
    _ = await fixture.insert(first)
    fixture.service.prepareForNextDictation()
    let second = await fixture.service.captureTarget().value
    _ = await fixture.service.insert("second transcript", into: second)
    XCTAssertEqual(fixture.board.string(forType: .string), "second transcript")
    await fixture.service.finishPendingRestoration()
    XCTAssertEqual(fixture.outcomes, [.cancelled, .restoredAfterRead])
    XCTAssertEqual(fixture.board.string(forType: .string), "original")
  }

  func testNewUserCopyBetweenDictationsBecomesTheNewBackup() async {
    let fixture = ReadFixture()
    defer { fixture.close() }
    let first = await fixture.service.captureTarget().value
    _ = await fixture.insert(first)
    fixture.board.clearContents()
    fixture.board.setString("new original", forType: .string)
    let second = await fixture.service.captureTarget().value
    _ = await fixture.insert(second)
    _ = fixture.board.string(forType: .string)
    await fixture.service.finishPendingRestoration()
    XCTAssertEqual(fixture.board.string(forType: .string), "new original")
  }

  func testSnapshotFinishingAfterCaptureIsAwaitedBeforePaste() async {
    let fixture = ReadFixture(snapshotDelay: 0.025)
    defer { fixture.close() }
    let target = await fixture.service.captureTarget().value
    _ = await fixture.insert(target)
    _ = fixture.board.string(forType: .string)
    await fixture.service.finishPendingRestoration()
    XCTAssertEqual(fixture.outcomes, [.restoredAfterRead])
    XCTAssertEqual(fixture.board.string(forType: .string), "original")
  }

  func testEmptyAndRichClipboardRepresentationsRoundTrip() async {
    for empty in [true, false] {
      let fixture = ReadFixture()
      defer { fixture.close() }
      fixture.board.clearContents()
      let custom = NSPasteboard.PasteboardType("test.rich-content")
      if !empty {
        let item = NSPasteboardItem()
        item.setString("rich text", forType: .string)
        item.setData(Data([0, 1, 2, 255]), forType: custom)
        fixture.board.writeObjects([item])
      }
      let target = await fixture.service.captureTarget().value
      _ = await fixture.insert(target)
      _ = fixture.board.string(forType: .string)
      await fixture.service.finishPendingRestoration()
      XCTAssertEqual(fixture.outcomes, [.restoredAfterRead])
      if empty { XCTAssertTrue(fixture.board.pasteboardItems?.isEmpty == true) }
      else { XCTAssertEqual(fixture.board.data(forType: custom), Data([0, 1, 2, 255])) }
    }
  }

  func testLateReadReceivesTheFullGracePeriod() async throws {
    let fixture = ReadFixture(timeout: .milliseconds(400), readGrace: .milliseconds(250))
    defer { fixture.close() }
    let target = await fixture.service.captureTarget().value
    _ = await fixture.insert(target)
    try await Task.sleep(for: .milliseconds(250))
    XCTAssertEqual(fixture.board.string(forType: .string), "transcript")
    await fixture.service.finishPendingRestoration()
    XCTAssertEqual(fixture.outcomes, [.restoredAfterRead])
    XCTAssertEqual(fixture.board.string(forType: .string), "original")
  }

  func testTargetChangeDuringReadGracePreventsRestore() async {
    let fixture = ReadFixture()
    defer { fixture.close() }
    let target = await fixture.service.captureTarget().value
    _ = await fixture.insert(target)
    _ = fixture.board.string(forType: .string)
    fixture.targetIsCurrent = false
    await fixture.service.finishPendingRestoration()
    XCTAssertEqual(fixture.outcomes, [.unverified])
    XCTAssertEqual(fixture.board.string(forType: .string), "transcript")
  }

  func testProviderCanFulfillFromBackgroundWithoutMainActorHop() async {
    let receipt = ClipboardReadReceipt(text: "transcript")
    receipt.beginDispatch()
    let supplied = await Task.detached {
      let item = NSPasteboardItem()
      receipt.pasteboard(nil, item: item, provideDataForType: .string)
      return item.string(forType: .string)
    }.value
    XCTAssertEqual(supplied, "transcript")
    XCTAssertNotNil(receipt.lastEligibleRead)
  }

  func testReadBeforeDispatchCannotAuthorizeRestoration() {
    let receipt = ClipboardReadReceipt(text: "transcript")
    let item = NSPasteboardItem()
    receipt.pasteboard(nil, item: item, provideDataForType: .string)
    receipt.beginDispatch()
    receipt.pasteboard(nil, item: item, provideDataForType: .string)
    XCTAssertNil(receipt.lastEligibleRead)
    XCTAssertEqual(item.string(forType: .string), "transcript")
  }

  func testMarkerRequestsDoNotCountAndStoppedProviderStillSuppliesText() {
    let receipt = ClipboardReadReceipt(text: "transcript")
    let item = NSPasteboardItem()
    receipt.beginDispatch()
    receipt.pasteboard(nil, item: item, provideDataForType: .init("test.marker"))
    XCTAssertNil(receipt.lastEligibleRead)
    receipt.stop()
    receipt.pasteboard(nil, item: item, provideDataForType: .string)
    XCTAssertNil(receipt.lastEligibleRead)
    XCTAssertEqual(item.string(forType: .string), "transcript")
  }
}

@MainActor
private final class ReadFixture {
  let board = NSPasteboard.withUniqueName()
  let restoration: ClipboardRestoration
  var outcomes: [ClipboardRestorationOutcome] = []
  var dispatchResult: TargetInsertionOutcome = .pasteSent
  var targetIsCurrent = true
  lazy var service = TextInsertionService(
    pasteboard: board,
    capture: { [weak self] in
      Task {
        TextInsertionTarget(verification: TextVerificationSource(
          prepare: { nil }, read: { nil }, isCurrent: { self?.targetIsCurrent == true }
        )) { commit in
          await commit({ nil }, { self?.dispatchResult ?? .blocked(.targetUnavailable) })
        }
      }
    },
    restoration: restoration, readAwareClipboard: true,
    makeRestorationReport: { [weak self] in { self?.outcomes.append($0) } })

  init(snapshotDelay: TimeInterval = 0, timeout: Duration = .milliseconds(150),
       readGrace: Duration = .milliseconds(20)) {
    board.setString("original", forType: .string)
    restoration = ClipboardRestoration(
      board: board,
      timing: .init(poll: .milliseconds(2), grace: .milliseconds(5), timeout: timeout,
                    readGrace: readGrace),
      readSnapshot: { name, count in
        if snapshotDelay > 0 {
          Thread.sleep(forTimeInterval: snapshotDelay)
          // Isolate worker-completion timing from pasteboard-server IPC latency.
          return ClipboardSnapshot(changeCount: count, items: [
            .init(representations: [.init(type: NSPasteboard.PasteboardType.string.rawValue,
                                         data: Data("original".utf8))]),
          ])
        }
        return ClipboardSnapshot.capture(from: NSPasteboard(name: .init(name)), expectedChangeCount: count)
      })
  }

  func insert(_ target: TextInsertionTarget?) async -> InsertionResult {
    await service.insert("transcript", into: target)
  }

  func close() {
    service.invalidatePendingRestoration()
    board.releaseGlobally()
  }
}

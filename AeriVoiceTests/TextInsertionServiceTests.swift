import AppKit
import XCTest

@testable import AeriVoice

@MainActor
final class TextInsertionServiceTests: XCTestCase {
  private func board() -> NSPasteboard {
    let board = NSPasteboard.withUniqueName()
    let name = board.name.rawValue
    addTeardownBlock { await MainActor.run { NSPasteboard(name: .init(name)).releaseGlobally() } }
    return board
  }

  func testPasteSentLeavesTranscriptAndNeverRestoresOldClipboard() async throws {
    let board = board()
    board.setString("old", forType: .string)
    let service = TextInsertionService(pasteboard: board)
    let target = TextInsertionTarget { authorize in
      await authorize({ nil }, { .pasteSent })
    }
    let result = await service.insert("transcript", into: target)
    XCTAssertEqual(result, .pasteSent)
    XCTAssertEqual(board.string(forType: .string), "transcript")
    let count = board.changeCount
    try await Task.sleep(for: .milliseconds(1100))
    XCTAssertEqual(board.changeCount, count)
    XCTAssertEqual(board.string(forType: .string), "transcript")
  }

  func testFocusChangeBeforeCommitRejectsActionAfterActorHop() async {
    let board = board()
    let focus = CommitFocus()
    let target = TextInsertionTarget { commit in
      await MainActor.run { focus.current = false }
      return await commit(
        { focus.current ? nil : .targetChanged },
        {
          focus.dispatches += 1
          return .pasteSent
        })
    }
    let result = await TextInsertionService(pasteboard: board).insert("transcript", into: target)
    guard case .copied = result else { return XCTFail("Changed field must copy only") }
    XCTAssertEqual(focus.dispatches, 0)
    XCTAssertEqual(board.string(forType: .string), "transcript")
  }

  func testUserCopyDuringFinalValidationPreventsClipboardCommit() async {
    let board = board()
    let name = board.name.rawValue
    let focus = CommitFocus()
    let target = TextInsertionTarget { commit in
      await commit(
        {
          let board = NSPasteboard(name: .init(name))
          board.clearContents()
          board.setString("user copy", forType: .string)
          return nil
        },
        {
          focus.dispatches += 1
          return .pasteSent
        })
    }
    let result = await TextInsertionService(pasteboard: board).insert("transcript", into: target)
    guard case .failed = result else { return XCTFail("Must not overwrite an intervening copy") }
    XCTAssertEqual(focus.dispatches, 0)
    XCTAssertEqual(board.string(forType: .string), "user copy")
  }

  func testNilTargetCopiesWithoutDispatching() async {
    let board = board()
    let result = await TextInsertionService(pasteboard: board).insert("transcript", into: nil)
    guard case .copied = result else { return XCTFail("Missing target must copy") }
    XCTAssertEqual(board.string(forType: .string), "transcript")
  }

  func testInterveningUserCopyRejectsDispatchWithoutOverwritingIt() async {
    let board = board()
    board.setString("old", forType: .string)
    let service = TextInsertionService(pasteboard: board)
    var dispatched = false
    let name = board.name.rawValue
    let target = TextInsertionTarget { authorize in
      await MainActor.run {
        let board = NSPasteboard(name: .init(name))
        board.clearContents()
        board.setString("user copy", forType: .string)
      }
      let permitted = await authorize({ nil }, { .pasteSent })
      await MainActor.run { dispatched = permitted == .pasteSent }
      return permitted
    }
    let result = await service.insert("transcript", into: target)
    guard case .failed = result else { return XCTFail("Do not claim copied") }
    XCTAssertFalse(dispatched)
    XCTAssertEqual(board.string(forType: .string), "user copy")
  }

  func testOwnershipIsRecheckedWithoutRewritingTranscript() async {
    let board = board()
    let name = board.name.rawValue
    let target = TextInsertionTarget { authorize in
      let first = await authorize({ nil }, { .pasteSent })
      XCTAssertEqual(first, .pasteSent)
      await MainActor.run {
        let board = NSPasteboard(name: .init(name))
        board.clearContents()
        board.setString("new copy", forType: .string)
      }
      let second = await authorize({ nil }, { .pasteSent })
      XCTAssertEqual(second, .pasteSent)
      return .blocked(.targetUnavailable)
    }
    let result = await TextInsertionService(pasteboard: board).insert("transcript", into: target)
    guard case .failed = result else { return XCTFail("Do not overwrite lost ownership") }
    XCTAssertEqual(board.string(forType: .string), "new copy")
  }

  func testConcurrentServicesCannotNestClipboardTransactions() async {
    let board = board()
    let first = TextInsertionService(pasteboard: board)
    let second = TextInsertionService(pasteboard: board)
    let target = TextInsertionTarget { authorize in
      let competing = await second.insert("wrong transcript", into: nil)
      guard case .failed = competing else {
        XCTFail("Second transaction must be rejected")
        return .blocked(.targetUnavailable)
      }
      return await authorize({ nil }, { .pasteSent })
    }
    _ = await first.insert("first transcript", into: target)
    XCTAssertEqual(board.string(forType: .string), "first transcript")
    // The owner is released on every terminal path.
    let next = await second.insert("next transcript", into: nil)
    guard case .copied = next else { return XCTFail("Transaction lock leaked") }
    XCTAssertEqual(board.string(forType: .string), "next transcript")
  }

  func testAlreadyCancelledInsertionDoesNotTouchClipboard() async {
    let board = board()
    board.setString("original", forType: .string)
    let service = TextInsertionService(pasteboard: board)
    let task = Task { await service.insert("transcript", into: nil) }
    task.cancel()
    let result = await task.value
    XCTAssertEqual(result, .cancelled)
    XCTAssertEqual(board.string(forType: .string), "original")
  }

  func testCancellationDuringPreparationDoesNotAuthorizePaste() async {
    let board = board()
    board.setString("original", forType: .string)
    let gate = InsertionGate()
    let target = TextInsertionTarget { authorize in
      await gate.pause()
      return await authorize({ nil }, { .pasteSent })
    }
    let service = TextInsertionService(pasteboard: board)
    let task = Task { await service.insert("transcript", into: target) }
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while gate.continuation == nil, ContinuousClock.now < deadline { await Task.yield() }
    guard gate.continuation != nil else {
      task.cancel()
      return XCTFail("Preparation did not reach the cancellation gate")
    }
    task.cancel()
    gate.continuation?.resume()
    let result = await task.value
    XCTAssertEqual(result, .cancelled)
    XCTAssertEqual(board.string(forType: .string), "original")
  }

  func testEveryRejectedTargetCopiesWithItsSpecificReason() async {
    for reason in PasteBlockReason.allCases where reason != .clipboardChanged {
      let board = board()
      let result = await TextInsertionService(pasteboard: board).insert(
        "transcript", into: .rejected(reason))
      XCTAssertEqual(result, .copied(reason))
      XCTAssertEqual(board.string(forType: .string), "transcript")
    }
  }

  func testCopyDuringCleanupPreservesUserClipboard() async {
    let board = board()
    board.setString("before stop", forType: .string)
    let service = TextInsertionService(
      pasteboard: board,
      capture: {
        Task { TextInsertionTarget { commit in await commit({ nil }, { .pasteSent }) } }
      })
    let target = await service.captureTarget().value
    board.clearContents()
    board.setString("new user copy", forType: .string)
    let result = await service.insert("transcript", into: target)
    guard case .failed = result else { return XCTFail("Must preserve a copy made during cleanup") }
    XCTAssertEqual(board.string(forType: .string), "new user copy")
  }

  func testPasteCanOnlyDispatchOnceAndWorksWithInitiallyEmptyClipboard() async {
    let board = board()
    board.clearContents()
    let focus = CommitFocus()
    let target = TextInsertionTarget { commit in
      let first = await commit(
        { nil },
        {
          focus.dispatches += 1
          return .pasteSent
        })
      let second = await commit(
        { nil },
        {
          focus.dispatches += 1
          return .pasteSent
        })
      XCTAssertEqual(first, .pasteSent)
      XCTAssertEqual(second, .pasteSent)
      return second
    }
    let result = await TextInsertionService(pasteboard: board).insert("transcript", into: target)
    XCTAssertEqual(result, .pasteSent)
    XCTAssertEqual(focus.dispatches, 1)
    XCTAssertEqual(board.string(forType: .string), "transcript")
  }

}

@MainActor
private final class CommitFocus {
  var current = true
  var dispatches = 0
}

@MainActor
private final class InsertionGate {
  var continuation: CheckedContinuation<Void, Never>?
  func pause() async { await withCheckedContinuation { continuation = $0 } }
}

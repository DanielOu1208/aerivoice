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

  func testDirectInsertionDoesNotTouchRichClipboard() async {
    let board = board()
    let item = NSPasteboardItem()
    item.setData(Data([1, 2, 3]), forType: .rtf)
    item.setString("original", forType: .string)
    board.writeObjects([item])
    let count = board.changeCount
    let service = TextInsertionService(pasteboard: board)
    let target = TextInsertionTarget { _, _ in .inserted }
    let result = await service.insert("transcript", into: target)
    XCTAssertEqual(result, .inserted)
    XCTAssertEqual(board.changeCount, count)
    XCTAssertEqual(board.data(forType: .rtf), Data([1, 2, 3]))
    XCTAssertEqual(board.string(forType: .string), "original")
  }

  func testRequestedPasteIsNotConfirmedAndNeverRestoresOldClipboard() async throws {
    let board = board()
    board.setString("old", forType: .string)
    let service = TextInsertionService(pasteboard: board)
    let target = TextInsertionTarget { _, authorize in
      await authorize({ true }, { .pasteRequested })
    }
    let result = await service.insert("transcript", into: target)
    guard case .unconfirmed = result else { return XCTFail("Posting is not insertion") }
    XCTAssertEqual(board.string(forType: .string), "transcript")
    let count = board.changeCount
    try await Task.sleep(for: .milliseconds(1100))
    XCTAssertEqual(board.changeCount, count)
    XCTAssertEqual(board.string(forType: .string), "transcript")
  }

  func testFocusChangeBeforeCommitRejectsActionAfterActorHop() async {
    let board = board()
    let focus = CommitFocus()
    let target = TextInsertionTarget { _, commit in
      await MainActor.run { focus.current = false }
      return await commit(
        { focus.current },
        {
          focus.dispatches += 1
          return .pasteRequested
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
    let target = TextInsertionTarget { _, commit in
      await commit(
        {
          let board = NSPasteboard(name: .init(name))
          board.clearContents()
          board.setString("user copy", forType: .string)
          return true
        },
        {
          focus.dispatches += 1
          return .pasteRequested
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
    let target = TextInsertionTarget { _, authorize in
      await MainActor.run {
        let board = NSPasteboard(name: .init(name))
        board.clearContents()
        board.setString("user copy", forType: .string)
      }
      let permitted = await authorize({ true }, { .pasteRequested })
      await MainActor.run { dispatched = permitted == .pasteRequested }
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
    let target = TextInsertionTarget { _, authorize in
      let first = await authorize({ true }, { .pasteRequested })
      XCTAssertEqual(first, .pasteRequested)
      await MainActor.run {
        let board = NSPasteboard(name: .init(name))
        board.clearContents()
        board.setString("new copy", forType: .string)
      }
      let second = await authorize({ true }, { .pasteRequested })
      XCTAssertEqual(second, .unavailable)
      return .unavailable
    }
    let result = await TextInsertionService(pasteboard: board).insert("transcript", into: target)
    guard case .failed = result else { return XCTFail("Do not overwrite lost ownership") }
    XCTAssertEqual(board.string(forType: .string), "new copy")
  }

  func testConcurrentServicesCannotNestClipboardTransactions() async {
    let board = board()
    let first = TextInsertionService(pasteboard: board)
    let second = TextInsertionService(pasteboard: board)
    let target = TextInsertionTarget { _, authorize in
      let competing = await second.insert("wrong transcript", into: nil)
      guard case .failed = competing else {
        XCTFail("Second transaction must be rejected")
        return .unavailable
      }
      return await authorize({ true }, { .pasteRequested })
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
    let target = TextInsertionTarget { _, authorize in
      await gate.pause()
      return await authorize({ true }, { .pasteRequested })
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

  func testUncertainMutationCopiesButDoesNotReportConfirmedInsertion() async {
    let board = board()
    let target = TextInsertionTarget { _, _ in .uncertain }
    let result = await TextInsertionService(pasteboard: board).insert("transcript", into: target)
    guard case .unconfirmed = result else { return XCTFail("Uncertain mutation must warn") }
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

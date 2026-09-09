import AppKit
import XCTest

@testable import AeriVoice

@MainActor
final class ClipboardSnapshotTests: XCTestCase {
  private let markerType = NSPasteboard.PasteboardType("com.aerivoice.tests.owner")
  private let marker = "test-owner"

  private func board() -> NSPasteboard {
    let board = NSPasteboard.withUniqueName()
    let name = board.name.rawValue
    addTeardownBlock { await MainActor.run { NSPasteboard(name: .init(name)).releaseGlobally() } }
    return board
  }

  private func own(_ board: NSPasteboard) -> Int {
    let item = NSPasteboardItem()
    XCTAssertTrue(item.setString("dictation", forType: .string))
    XCTAssertTrue(item.setString(marker, forType: markerType))
    board.clearContents()
    XCTAssertTrue(board.writeObjects([item]))
    return board.changeCount
  }

  private func snapshot() -> ClipboardSnapshot {
    ClipboardSnapshot(changeCount: 0, items: [
      .init(representations: [.init(type: NSPasteboard.PasteboardType.string.rawValue,
                                   data: Data("original".utf8))])
    ])
  }

  func testCaptureAndRestorePreserveOrderedItemsAndRepresentations() throws {
    let board = board()
    let first = NSPasteboardItem()
    let second = NSPasteboardItem()
    let binaryType = NSPasteboard.PasteboardType("com.aerivoice.tests.binary")
    XCTAssertTrue(first.setString("original 😀", forType: .string))
    XCTAssertTrue(first.setData(Data([0, 255, 1, 0]), forType: binaryType))
    XCTAssertTrue(second.setData(Data([3, 2, 1]), forType: binaryType))
    XCTAssertTrue(board.writeObjects([first, second]))
    let initialCount = board.changeCount
    let saved = try XCTUnwrap(ClipboardSnapshot.capture(from: board, expectedChangeCount: initialCount))
    XCTAssertEqual(board.changeCount, initialCount)
    XCTAssertEqual(saved.items.map { $0.representations.map(\.type) },
                   [first.types.map(\.rawValue), second.types.map(\.rawValue)])
    XCTAssertEqual(saved.items[0].representations[1].data, Data([0, 255, 1, 0]))
    let owned = own(board)
    XCTAssertEqual(saved.restore(to: board, markerType: markerType, marker: marker,
                                 ownedChangeCount: owned, dictation: "dictation"), .restored)
    let restored = try XCTUnwrap(ClipboardSnapshot.capture(from: board, expectedChangeCount: board.changeCount))
    XCTAssertEqual(restored.items, saved.items)
    XCTAssertNil(board.string(forType: markerType))
  }

  func testActualEmptyPasteboardIsSuccessfulEmptySnapshotAndRestoresByClearing() throws {
    let board = board()
    board.clearContents()
    XCTAssertNotNil(board.pasteboardItems)
    XCTAssertEqual(board.pasteboardItems?.count, 0)
    let saved = try XCTUnwrap(ClipboardSnapshot.capture(from: board, expectedChangeCount: board.changeCount))
    XCTAssertTrue(saved.items.isEmpty)
    let owned = own(board)
    XCTAssertEqual(saved.restore(to: board, markerType: markerType, marker: marker,
                                 ownedChangeCount: owned, dictation: "dictation",
                                 write: { _ in XCTFail("Empty restoration must only clear"); return false }), .restored)
    XCTAssertEqual(board.pasteboardItems?.count, 0)
  }

  func testUnavailableItemsOrAdvertisedDataRejectWholeSnapshot() {
    XCTAssertNil(ClipboardSnapshot.capture(expectedChangeCount: 1, changeCount: { 1 },
      items: { Optional<[Int]>.none }, types: { _ in ["text"] }, data: { _, _ in Data() }))
    XCTAssertNil(ClipboardSnapshot.capture(expectedChangeCount: 1, changeCount: { 1 },
      items: { [0, 1] }, types: { _ in ["text"] }, data: { item, _ in item == 0 ? Data([1]) : nil }))
  }

  func testCapsApplyToWholeSnapshotAndAcceptExactBoundary() {
    func capture(_ limits: ClipboardSnapshot.Limits) -> ClipboardSnapshot? {
      ClipboardSnapshot.capture(expectedChangeCount: 1, limits: limits, changeCount: { 1 },
        items: { [0, 1] }, types: { _ in ["first", "second"] }, data: { _, _ in Data([1, 2]) })
    }
    XCTAssertNotNil(capture(.init(maximumBytes: 8, maximumItems: 2, maximumRepresentations: 4)))
    XCTAssertNil(capture(.init(maximumBytes: 7, maximumItems: 2, maximumRepresentations: 4)))
    XCTAssertNil(capture(.init(maximumBytes: 8, maximumItems: 1, maximumRepresentations: 4)))
    XCTAssertNil(capture(.init(maximumBytes: 8, maximumItems: 2, maximumRepresentations: 3)))
  }

  func testCountChangesAtEveryReadBoundaryRejectCapture() {
    for changedRead in 1...7 {
      var reads = 0
      let saved = ClipboardSnapshot.capture(expectedChangeCount: 1,
        changeCount: { reads += 1; return reads >= changedRead ? 2 : 1 },
        items: { [0] }, types: { _ in ["text"] }, data: { _, _ in Data([1]) })
      XCTAssertNil(saved, "Changed count at read \(changedRead)")
    }
  }

  func testProviderChangingCountRejectsMaterializedData() {
    var count = 1
    XCTAssertNil(ClipboardSnapshot.capture(expectedChangeCount: 1, changeCount: { count },
      items: { [0] }, types: { _ in ["text"] }, data: { _, _ in count = 2; return Data([1]) }))
  }

  func testLostCountOrMarkerDoesNotMutateClipboard() {
    for staleCount in [false, true] {
      let board = board()
      let owned = own(board)
      let count = board.changeCount
      XCTAssertEqual(snapshot().restore(to: board, markerType: markerType,
        marker: staleCount ? marker : "different-owner",
        ownedChangeCount: staleCount ? owned - 1 : owned, dictation: "dictation"), .superseded)
      XCTAssertEqual(board.changeCount, count)
      XCTAssertEqual(board.string(forType: .string), "dictation")
    }
  }

  func testFailedWriteRecoversDictationAndMarkerOnlyOnOurEmptyClear() {
    let board = board()
    let owned = own(board)
    var attempts = 0
    XCTAssertEqual(snapshot().restore(to: board, markerType: markerType, marker: marker,
      ownedChangeCount: owned, dictation: "dictation", write: { items in
        attempts += 1
        return attempts == 1 ? false : board.writeObjects(items)
      }), .failed)
    XCTAssertEqual(attempts, 2)
    XCTAssertEqual(board.string(forType: .string), "dictation")
    XCTAssertEqual(board.string(forType: markerType), marker)
  }

  func testFailedWriteDoesNotOverwriteInterveningCopyOrPartialWriteOrNewEmptyBoard() {
    for replacement in ["user copy", "partial", ""] {
      let board = board()
      let owned = own(board)
      var attempts = 0
      XCTAssertEqual(snapshot().restore(to: board, markerType: markerType, marker: marker,
        ownedChangeCount: owned, dictation: "dictation", write: { _ in
          attempts += 1
          if replacement != "partial" { board.clearContents() }
          if !replacement.isEmpty { board.setString(replacement, forType: .string) }
          return false
        }), .failed)
      XCTAssertEqual(attempts, 1)
      XCTAssertEqual(board.string(forType: .string), replacement.isEmpty ? nil : replacement)
      XCTAssertNil(board.string(forType: markerType))
    }
  }

  func testFallbackFailureDoesNotRetryAgain() {
    let board = board()
    let owned = own(board)
    var attempts = 0
    XCTAssertEqual(snapshot().restore(to: board, markerType: markerType, marker: marker,
      ownedChangeCount: owned, dictation: "dictation", write: { _ in attempts += 1; return false }), .failed)
    XCTAssertEqual(attempts, 2)
    XCTAssertEqual(board.pasteboardItems?.count, 0)
  }
}

import AppKit
import XCTest

@testable import AeriVoice

@MainActor
final class NotchPanelPinningTests: XCTestCase {
  func testHiddenPanelStaysOrderedAndJoinsEverySpace() {
    let panel = NSPanel(
      contentRect: CGRect(x: 0, y: 0, width: 220, height: 1),
      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    defer { panel.close() }

    NotchPanelPinning.configure(panel)
    NotchPanelPinning.keepOrderedWhileHidden(panel)

    XCTAssertTrue(panel.isVisible)
    XCTAssertEqual(panel.alphaValue, 0)
    XCTAssertFalse(panel.hidesOnDeactivate)
    XCTAssertFalse(panel.isMovable)
    XCTAssertTrue(panel.ignoresMouseEvents)
    XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllSpaces))
    XCTAssertTrue(panel.collectionBehavior.contains(.fullScreenAuxiliary))
    XCTAssertTrue(panel.collectionBehavior.contains(.stationary))
  }

  func testVisiblePanelIsReraisedOnPhaseChangesButNotTranscriptUpdates() {
    var recording = NotchState(phase: .recording)
    var updated = recording
    updated.transcript = TranscriptSnapshot(confirmed: "hello")
    XCTAssertFalse(NotchPanelPinning.reordersVisiblePanel(from: recording, to: updated))
    recording.warning = "Output could not be muted"
    XCTAssertFalse(NotchPanelPinning.reordersVisiblePanel(from: updated, to: recording))
    XCTAssertTrue(
      NotchPanelPinning.reordersVisiblePanel(from: updated, to: NotchState(phase: .processing)))
  }

  func testKeepingResidentPanelHiddenDoesNotOrderItAgain() {
    let panel = OrderingCountPanel(
      contentRect: CGRect(x: 0, y: 0, width: 220, height: 40),
      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    defer { panel.close() }
    NotchPanelPinning.configure(panel)
    NotchPanelPinning.keepOrderedWhileHidden(panel)
    let initialCount = panel.orderingCount
    NotchPanelPinning.keepOrderedWhileHidden(panel)
    XCTAssertEqual(panel.orderingCount, initialCount)
    XCTAssertTrue(panel.isVisible)
  }
}

@MainActor
private final class OrderingCountPanel: NSPanel {
  var orderingCount = 0
  override func orderFrontRegardless() {
    orderingCount += 1
    super.orderFrontRegardless()
  }
}

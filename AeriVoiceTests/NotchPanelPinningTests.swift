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

  func testOpeningFromPinnedHiddenUsesCollapsedFrame() {
    let current = CGRect(x: 10, y: 20, width: 300, height: 60)
    let collapsed = CGRect(x: 50, y: 70, width: 220, height: 38)

    XCTAssertEqual(
      NotchPanelPinning.openingFrame(
        panelAlpha: 0, currentFrame: current, collapsedFrame: collapsed),
      collapsed)
  }

  func testOpeningDuringHideKeepsCurrentFrame() {
    let current = CGRect(x: 10, y: 20, width: 300, height: 60)
    let collapsed = CGRect(x: 50, y: 70, width: 220, height: 38)

    XCTAssertEqual(
      NotchPanelPinning.openingFrame(
        panelAlpha: 1, currentFrame: current, collapsedFrame: collapsed),
      current)
  }
}

import AppKit
import SwiftUI
import XCTest

@testable import AeriVoice

@MainActor
final class SettingsSplitViewTests: XCTestCase {
  func testSettingsLayoutPreservesSidebarAndKeepsContentBelowToolbar() async throws {
    let controller = SettingsSplitViewController(
      sidebar: Text("Sidebar").frame(maxWidth: .infinity, maxHeight: .infinity),
      detail: Text("General").frame(maxWidth: .infinity, maxHeight: .infinity))
    let sidebar = try XCTUnwrap(controller.splitViewItems.first)
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 780, height: 640),
      styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
    window.contentMinSize = NSSize(width: 700, height: 560)
    window.contentViewController = controller
    window.toolbar = controller.makeToolbar()
    window.orderFront(nil)
    defer { window.orderOut(nil) }
    try await Task.sleep(for: .milliseconds(50))
    controller.view.layoutSubtreeIfNeeded()
    // AppKit insets the hosted view inside its full-height sidebar material.
    let sidebarContainer = try XCTUnwrap(controller.splitView.arrangedSubviews.first)
    XCTAssertEqual(sidebarContainer.frame.width, 200, accuracy: 1)
    let page = try XCTUnwrap(controller.splitViewItems.last?.viewController.children.first?.view)
    XCTAssertGreaterThan(page.frame.height, 0)
    XCTAssertLessThanOrEqual(
      page.convert(page.bounds, to: nil).maxY, window.contentLayoutRect.maxY + 1)

    let toggle = NSMenuItem(
      title: "Toggle Sidebar", action: #selector(NSSplitViewController.toggleSidebar(_:)),
      keyEquivalent: "s")
    XCTAssertFalse(controller.validateUserInterfaceItem(toggle))
    controller.toggleSidebar(nil)
    XCTAssertFalse(sidebar.isCollapsed)
    XCTAssertFalse(
      controller.splitView(controller.splitView, canCollapseSubview: sidebar.viewController.view))

    window.setContentSize(NSSize(width: 700, height: 560))
    controller.view.layoutSubtreeIfNeeded()
    XCTAssertFalse(sidebar.isCollapsed)
    XCTAssertGreaterThanOrEqual(sidebarContainer.frame.width, 180)
    XCTAssertLessThanOrEqual(sidebarContainer.frame.width, 240)
    XCTAssertLessThanOrEqual(
      page.convert(page.bounds, to: nil).maxY, window.contentLayoutRect.maxY + 1)

    window.setContentSize(NSSize(width: 1000, height: 700))
    controller.view.layoutSubtreeIfNeeded()
    XCTAssertFalse(sidebar.isCollapsed)
    XCTAssertTrue(controller.splitViewItems.first === sidebar)
  }
}

import AppKit
import XCTest

@testable import AeriVoice

@MainActor
final class AppDelegateTests: XCTestCase {
  func testSettingsWindowControlsDockVisibilityPolicy() {
    XCTAssertEqual(AppDelegate.activationPolicy(settingsWindowVisible: true), .regular)
    XCTAssertEqual(AppDelegate.activationPolicy(settingsWindowVisible: false), .accessory)
  }

  func testMainMenuProvidesStandardPasteCommand() throws {
    let mainMenu = AppDelegate.makeMainMenu()
    let editMenu = try XCTUnwrap(mainMenu.items.compactMap(\.submenu).first { $0.title == "Edit" })
    let paste = try XCTUnwrap(editMenu.items.first { $0.action == #selector(NSText.paste(_:)) })

    XCTAssertEqual(paste.keyEquivalent, "v")
    XCTAssertEqual(paste.keyEquivalentModifierMask, .command)
  }
}

import AppKit
import XCTest

@testable import AeriVoice

@MainActor
final class SettingsComponentsTests: XCTestCase {
  func testCredentialPasteReadsPlainTextFromPasteboard() throws {
    let pasteboard = NSPasteboard(name: .init("AeriVoiceTests.\(UUID().uuidString)"))
    pasteboard.clearContents()
    pasteboard.setString("qa-api-key", forType: .string)

    XCTAssertEqual(CredentialInput.pastedValue(from: pasteboard), "qa-api-key")
  }

  func testCredentialPasteIgnoresPasteboardWithoutPlainText() {
    let pasteboard = NSPasteboard(name: .init("AeriVoiceTests.\(UUID().uuidString)"))
    pasteboard.clearContents()
    pasteboard.setData(Data([0x01]), forType: .pdf)

    XCTAssertNil(CredentialInput.pastedValue(from: pasteboard))
  }
}

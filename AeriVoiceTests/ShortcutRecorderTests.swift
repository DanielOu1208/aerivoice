import XCTest

@testable import AeriVoice

@MainActor
final class ShortcutRecorderTests: XCTestCase {
  func testModifierOnlyChordCommitsAndUpdatesDisplay() {
    let recorder = ShortcutRecorderNSView()
    var captured: ShortcutDefinition?
    recorder.onCapture = { captured = $0 }

    recorder.captureModifierFlags([.option])
    recorder.captureModifierFlags([.option, .command])
    recorder.captureModifierFlags([.command])
    recorder.captureModifierFlags([])

    XCTAssertEqual(captured?.displayName, "⌥⌘")
    XCTAssertEqual(captured?.isModifierOnly, true)
    XCTAssertEqual(recorder.displayName, "⌥⌘")
  }
}

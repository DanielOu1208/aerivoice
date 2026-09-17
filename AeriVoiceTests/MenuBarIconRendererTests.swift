import AppKit
import XCTest

@testable import AeriVoice

@MainActor
final class MenuBarIconRendererTests: XCTestCase {
  func testRecordingRendersNativeOrangeInBothAppearances() throws {
    let source = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
      NSColor.black.setFill()
      NSRect(x: 4, y: 4, width: 10, height: 10).fill()
      return true
    }
    source.isTemplate = true

    for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
      let appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
      appearance.performAsCurrentDrawingAppearance {
        do {
          let recording = MenuBarIconRenderer.image(from: source, recording: true)
          XCTAssertFalse(recording.isTemplate, "The status bar must preserve recording colors")
          let pixels = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 18, pixelsHigh: 18,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
          NSGraphicsContext.saveGraphicsState()
          defer { NSGraphicsContext.restoreGraphicsState() }
          NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: pixels)
          recording.draw(in: NSRect(x: 0, y: 0, width: 18, height: 18))
          let actual = try XCTUnwrap(pixels.colorAt(x: 9, y: 9)?.usingColorSpace(.deviceRGB))
          let expected = try XCTUnwrap(NSColor.systemOrange.usingColorSpace(.deviceRGB))
          XCTAssertEqual(actual.redComponent, expected.redComponent, accuracy: 0.02)
          XCTAssertEqual(actual.greenComponent, expected.greenComponent, accuracy: 0.02)
          XCTAssertEqual(actual.blueComponent, expected.blueComponent, accuracy: 0.02)
          XCTAssertEqual(actual.alphaComponent, 1, accuracy: 0.01)
          XCTAssertEqual(pixels.colorAt(x: 0, y: 0)?.alphaComponent, 0)
        } catch {
          XCTFail("Could not render recording icon: \(error)")
        }
      }
    }
    XCTAssertTrue(source.isTemplate, "Rendering orange must not alter the shared asset")
    XCTAssertTrue(MenuBarIconRenderer.image(from: source, recording: false).isTemplate)
  }
}

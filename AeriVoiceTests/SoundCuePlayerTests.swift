import AppKit
import XCTest

@testable import AeriVoice

@MainActor
final class SoundCuePlayerTests: XCTestCase {
  func testNativeCueMappingsAreAvailable() throws {
    let expectedNames: [DictationCue: String] = [
      .start: "Blow",
      .stop: "Bottle",
      .error: "Submarine",
    ]

    for cue in DictationCue.allCases {
      let soundName = SoundCuePlayer.nativeSoundName(for: cue)
      XCTAssertEqual(soundName, try XCTUnwrap(expectedNames[cue]))
      XCTAssertNotNil(NSSound(named: soundName))
    }
  }

  func testStartCueDelayCoversTheAudibleBlowAttack() {
    XCTAssertEqual(SoundCuePlayer().startCaptureDelay, .milliseconds(300))
  }
}

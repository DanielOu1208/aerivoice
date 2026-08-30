import AVFoundation
import XCTest

@testable import AeriVoice

@MainActor
final class SoundCuePlayerTests: XCTestCase {
  func testBundledCuesAreMonoPCMWithExpectedDurations() throws {
    let expectedDurations: [DictationCue: ClosedRange<Double>] = [
      .start: 0.085...0.095,
      .stop: 0.115...0.125,
      .error: 0.175...0.185,
    ]

    for cue in DictationCue.allCases {
      let url = try XCTUnwrap(SoundCuePlayer.resourceURL(for: cue, in: .main))
      let file = try AVAudioFile(forReading: url)
      let duration = Double(file.length) / file.processingFormat.sampleRate

      XCTAssertEqual(file.processingFormat.channelCount, 1)
      XCTAssertEqual(file.processingFormat.sampleRate, 44_100, accuracy: 0.1)
      XCTAssertTrue(try XCTUnwrap(expectedDurations[cue]).contains(duration))
    }
  }

  func testStartCueDelayCoversTheBundledStartSound() {
    XCTAssertEqual(SoundCuePlayer().startCaptureDelay, .milliseconds(140))
  }
}

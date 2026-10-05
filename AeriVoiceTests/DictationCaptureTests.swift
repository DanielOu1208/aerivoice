import Foundation
import XCTest

@testable import AeriVoice

@MainActor
final class DictationCaptureTests: XCTestCase {
  private typealias FakeAudio = DictationCoordinatorTests.FakeAudioCapture

  private func makeCapture(waitsForStart: Bool = false) -> (DictationCapture, FakeAudio) {
    let audio = FakeAudio(frameCount: 0, waitsForStartResolution: waitsForStart)
    return (DictationCapture(audio: audio, benchmark: DictationCoordinatorTests.BenchmarkSpy()), audio)
  }

  func testAPressARecordingAndAReleaseMoveThroughEachState() async throws {
    let (capture, audio) = makeCapture()
    audio.holdsReleaseStopUntilFinished = true
    XCTAssertFalse(capture.isStarting)
    XCTAssertFalse(capture.isOpen)

    capture.startEarly()
    XCTAssertTrue(capture.isStarting)
    XCTAssertTrue(capture.startedEarly)

    _ = try await capture.start(discardingAudioBefore: nil)
    XCTAssertTrue(capture.isStarting, "Not recording until the session says so")
    XCTAssertFalse(capture.startedEarly)
    XCTAssertEqual(audio.startRequestsDecliningBluetooth, [true], "The press's start was taken over")

    capture.beganRecording()
    XCTAssertFalse(capture.isStarting)
    XCTAssertTrue(capture.isOpen)

    let closing = try XCTUnwrap(capture.beginClose(atRelease: 42))
    XCTAssertTrue(capture.isOpen, "Still recording until the block that holds the release arrives")
    XCTAssertNil(capture.beginClose(atRelease: 43), "A release already in progress is not repeated")
    audio.finishReleaseStop()
    let closed = await capture.finishClose(closing)

    XCTAssertTrue(closed)
    XCTAssertFalse(capture.isOpen)
    XCTAssertEqual(audio.releaseStopHostTimes, [42])
  }

  func testAStopDuringTheReleaseWaitClosesTheMicrophoneOnce() async throws {
    let (capture, audio) = makeCapture()
    audio.holdsReleaseStopUntilFinished = true
    _ = try await capture.start(discardingAudioBefore: nil)
    capture.beganRecording()
    let closing = try XCTUnwrap(capture.beginClose(atRelease: 42))

    XCTAssertNotNil(capture.stop(), "A cancel or a failure closes the microphone at once")
    let closed = await capture.finishClose(closing)

    XCTAssertFalse(closed, "The release finds the microphone already closed")
    XCTAssertFalse(capture.isOpen)
    XCTAssertNil(capture.stop())
    XCTAssertEqual(audio.stopCount, 1)
  }

  func testStoppingAStartInFlightCancelsItWithoutStoppingARecording() async throws {
    let (capture, audio) = makeCapture(waitsForStart: true)
    capture.startEarly()
    try await waitUntil { audio.hasPendingStart }

    XCTAssertNil(capture.stop())

    XCTAssertFalse(capture.isStarting)
    XCTAssertEqual(audio.cancelStartCount, 1)
    XCTAssertEqual(audio.stopCount, 0)
    audio.resolveStart()
  }

  func testAnInputLostBeforeTheSessionFailsTheStartThatTakesItOver() async throws {
    let (capture, audio) = makeCapture()
    capture.startEarly()
    try await waitUntil { audio.startReturned }
    capture.inputLostBeforeSession()

    do {
      _ = try await capture.start(discardingAudioBefore: nil)
      XCTFail("Expected the microphone error")
    } catch AppError.microphoneUnavailable {
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
    XCTAssertTrue(capture.isStarting, "The session's failure closes it")
  }

  func testAnAbandonedStartPreparesTheNextEngineAndNothingElseDoes() async throws {
    let (capture, audio) = makeCapture()
    XCTAssertFalse(capture.abandonEarlyStart(), "Nothing was requested at the press")
    XCTAssertEqual(audio.cancelStartCount, 0)

    capture.startEarly()
    XCTAssertTrue(capture.abandonEarlyStart())

    XCTAssertFalse(capture.isStarting)
    XCTAssertEqual(audio.cancelStartCount, 1)
    try await waitUntil { audio.prepareCount == 1 }
  }

  func testAStartFromAnEarlierPressDoesNotTakeOverALaterOne() async throws {
    let (capture, audio) = makeCapture(waitsForStart: true)
    capture.startEarly()
    try await waitUntil { audio.hasPendingStart }
    let first = Task { try await capture.start(discardingAudioBefore: nil) }
    for _ in 0..<10 { await Task.yield() }

    // The first press's microphone finishes starting, but Escape and a new press are handled
    // before its session gets to take it over.
    audio.resolveStart()
    capture.stop()
    capture.startEarly()

    do {
      _ = try await first.value
      XCTFail("Expected the first session's start to end")
    } catch is CancellationError {
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
    XCTAssertTrue(capture.startedEarly, "The later press keeps its own start")
    try await waitUntil { audio.hasPendingStart }
    capture.stop()
    audio.resolveStart()
  }

  private func waitUntil(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while !condition(), ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(1))
    }
    XCTAssertTrue(condition(), "Timed out waiting for the capture")
  }
}

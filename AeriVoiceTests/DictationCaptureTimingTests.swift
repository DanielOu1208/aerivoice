import Foundation
import XCTest

@testable import AeriVoice

extension DictationCoordinatorTests {
  func testMicrophoneStartsDuringCueAndDropsAudioBeforeTheDeadline() async throws {
    let fixture = makeFixture(soundCues: true, cueDelay: .milliseconds(120))
    fixture.preferences.muteOutput = true
    let pressed = ContinuousClock.now
    fixture.coordinator.toggle()
    try await waitUntil { fixture.audio.didStart }

    // Startup overlaps the cue; output stays unmuted so the cue can play.
    XCTAssertFalse(fixture.muter.didMute)
    XCTAssertEqual(fixture.coordinator.phase, .starting)
    let deadline = try XCTUnwrap(fixture.audio.discardDeadline)
    XCTAssertGreaterThanOrEqual(deadline, pressed.advanced(by: .milliseconds(120)))

    try await waitUntil { fixture.coordinator.phase == .recording }
    XCTAssertTrue(fixture.muter.didMute)
    XCTAssertGreaterThanOrEqual(ContinuousClock.now, deadline)
    fixture.coordinator.cancel()
  }

  func testWithoutCuesAudioIsKeptFromTheStart() async throws {
    let fixture = makeFixture()
    fixture.coordinator.toggle()
    try await waitUntil { fixture.coordinator.phase == .recording }
    XCTAssertNil(fixture.audio.discardDeadline)
    fixture.coordinator.cancel()
  }

  func testCaptureContinuesBrieflyAfterStopAndStopCueFollowsIt() async throws {
    let fixture = makeFixture(soundCues: true, captureTail: .milliseconds(150))
    fixture.coordinator.toggle()
    try await waitUntil { fixture.coordinator.phase == .recording }

    fixture.coordinator.toggle()
    try await Task.sleep(for: .milliseconds(60))
    XCTAssertFalse(fixture.audio.didStop)
    XCTAssertEqual(fixture.cuePlayer.playedCues, [.start])
    XCTAssertEqual(fixture.coordinator.phase, .recording)

    try await waitUntil { fixture.audio.didStop }
    XCTAssertEqual(fixture.cuePlayer.playedCues, [.start, .stop])
    try await waitUntil { fixture.coordinator.phase == .success }
    XCTAssertEqual(fixture.inserter.insertedText, "Cleaned text.")
    XCTAssertEqual(fixture.audio.stopCount, 1)
  }

  func testCancellingDuringTheTailNeverProcesses() async throws {
    let fixture = makeFixture(captureTail: .milliseconds(150))
    fixture.coordinator.toggle()
    try await waitUntil { fixture.coordinator.phase == .recording }

    fixture.coordinator.toggle()
    try await Task.sleep(for: .milliseconds(30))
    fixture.coordinator.cancel()
    try await Task.sleep(for: .milliseconds(200))

    XCTAssertTrue(fixture.audio.didStop)
    XCTAssertEqual(fixture.benchmark.terminalResult, .cancelled)
    XCTAssertNil(fixture.inserter.insertedText)
    XCTAssertEqual(fixture.transcriber.flushCount, 0)
  }

  func testInterruptedCaptureFinishesWithTheAudioAlreadyRecorded() async throws {
    let fixture = makeFixture(captureTail: .milliseconds(500))
    fixture.coordinator.toggle()
    try await waitUntil { fixture.coordinator.phase == .recording }

    fixture.audio.onCaptureInterrupted?()
    // The tail is skipped: the input is already gone.
    try await waitUntil(timeout: .milliseconds(400)) { fixture.coordinator.phase == .success }
    XCTAssertEqual(fixture.inserter.insertedText, "Cleaned text.")
    XCTAssertTrue(
      fixture.notch.presentedStates.contains { $0.warning == "Microphone disconnected" })
  }

  func testInterruptionDuringCueFailsTheDictation() async throws {
    let fixture = makeFixture(soundCues: true, cueDelay: .milliseconds(150))
    fixture.coordinator.toggle()
    try await waitUntil { fixture.audio.didStart }

    fixture.audio.onCaptureInterrupted?()
    try await waitUntil { fixture.benchmark.terminalResult == .failed }
    XCTAssertEqual(fixture.benchmark.failureStage, .audioCapture)
    XCTAssertTrue(fixture.audio.didStop)
    XCTAssertTrue(fixture.transcriber.sentFrames.isEmpty)
  }

  func testNextCaptureIsPreparedAfterStopButNotAfterCancel() async throws {
    let fixture = makeFixture()
    fixture.coordinator.toggle()
    try await waitUntil { fixture.coordinator.phase == .recording }
    fixture.coordinator.toggle()
    try await waitUntil { fixture.coordinator.phase == .success }
    try await waitUntil { fixture.audio.prepareCount == 1 }

    let cancelled = makeFixture()
    cancelled.coordinator.toggle()
    try await waitUntil { cancelled.coordinator.phase == .recording }
    cancelled.coordinator.cancel()
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertEqual(cancelled.audio.prepareCount, 0)
  }
}

import Foundation
import XCTest

@testable import AeriVoice

extension DictationCoordinatorTests {
  func testMicrophoneStartsDuringCueAndDropsAudioBeforeTheDeadline() async throws {
    let fixture = makeFixture(soundCues: true, cueDelay: .milliseconds(120))
    fixture.preferences.muteOutput = true
    let pressed = ContinuousClock.now
    fixture.coordinator.toggle()
    // With cues on, the cue wait already hides the engine start; nothing starts at the press.
    XCTAssertFalse(fixture.benchmark.milestones.contains(.audioEngineStartRequested))
    try await waitUntil { fixture.audio.didStart }

    // Startup overlaps the cue; output stays unmuted so the cue can play.
    XCTAssertFalse(fixture.muter.didMute)
    XCTAssertEqual(fixture.coordinator.phase, .starting)
    let deadline = try XCTUnwrap(fixture.audio.discardDeadline)
    XCTAssertGreaterThanOrEqual(deadline, pressed.advanced(by: .milliseconds(120)))
    XCTAssertEqual(fixture.audio.startRequestsDecliningBluetooth, [false])

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

  func testStopClosesMicrophoneBeforeStopCue() async throws {
    let fixture = makeFixture(soundCues: true)
    fixture.coordinator.toggle()
    try await waitUntil { fixture.coordinator.phase == .recording }

    fixture.coordinator.toggle()
    // No wait after stop: the microphone is closed before the stop cue plays.
    XCTAssertTrue(fixture.audio.didStop)
    XCTAssertEqual(fixture.audio.stopCount, 1)
    XCTAssertEqual(fixture.cuePlayer.playedCues, [.start, .stop])
    try await waitUntil { fixture.coordinator.phase == .success }
    XCTAssertEqual(fixture.inserter.insertedText, "Cleaned text.")
    XCTAssertEqual(fixture.audio.stopCount, 1)
  }

  func testInterruptedCaptureFinishesWithTheAudioAlreadyRecorded() async throws {
    let fixture = makeFixture()
    fixture.coordinator.toggle()
    try await waitUntil { fixture.coordinator.phase == .recording }

    fixture.audio.onCaptureInterrupted?()
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

  // MARK: - The next engine is prepared

  func testNextCaptureIsPreparedAfterStop() async throws {
    let fixture = makeFixture()
    fixture.coordinator.toggle()
    try await waitUntil { fixture.coordinator.phase == .recording }
    fixture.coordinator.toggle()
    try await waitUntil { fixture.coordinator.phase == .success }
    try await waitUntil { fixture.audio.prepareCount == 1 }
    XCTAssertEqual(fixture.audio.discardCount, 0)
  }

  func testUserCancelWhileRecordingPreparesTheNextCapture() async throws {
    let fixture = makeFixture()
    fixture.coordinator.toggle()
    try await waitUntil { fixture.coordinator.phase == .recording }
    fixture.coordinator.cancel()
    XCTAssertTrue(fixture.audio.didStop)
    try await waitUntil { fixture.audio.prepareCount == 1 }
    XCTAssertEqual(fixture.audio.discardCount, 0)
  }

  func testCancelDuringEngineStartPreparesTheNextCapture() async throws {
    let fixture = makeFixture(audioStartWaitsForResolution: true)
    fixture.coordinator.toggle()
    try await waitUntil { fixture.audio.hasPendingStart }
    fixture.coordinator.cancel()
    XCTAssertEqual(fixture.audio.cancelStartCount, 1)
    try await waitUntil { fixture.audio.prepareCount == 1 }
    XCTAssertEqual(fixture.audio.discardCount, 0)
    fixture.audio.resolveStart()
    try await waitUntil { fixture.audio.startReturned }
    XCTAssertTrue(fixture.audio.startWasCancelled)
  }

  func testCancelDuringStartWithoutEarlyMicrophonePreparesTheNextCapture() async throws {
    let fixture = makeFixture(
      readiness: FakeReadiness(microphoneAuthorized: false), audioStartWaitsForResolution: true)
    fixture.coordinator.toggle()
    try await waitUntil { fixture.audio.hasPendingStart }
    fixture.coordinator.cancel()
    XCTAssertEqual(fixture.audio.cancelStartCount, 1)
    try await waitUntil { fixture.audio.prepareCount == 1 }
    fixture.audio.resolveStart()
    try await waitUntil { fixture.audio.startReturned }
    XCTAssertTrue(fixture.audio.startWasCancelled)
  }

  func testSuspensionDiscardsTheEngineWithoutPreparingAnother() async throws {
    for audioStartWaits in [false, true] {
      let fixture = makeFixture(audioStartWaitsForResolution: audioStartWaits)
      fixture.coordinator.toggle()
      if audioStartWaits {
        try await waitUntil { fixture.audio.hasPendingStart }
      } else {
        try await waitUntil { fixture.coordinator.phase == .recording }
      }
      fixture.coordinator.cancelForSuspension()
      XCTAssertTrue(fixture.audio.didStop)
      XCTAssertEqual(fixture.audio.discardCount, 1)
      XCTAssertEqual(fixture.benchmark.terminalResult, .cancelled)
      try await Task.sleep(for: .milliseconds(50))
      XCTAssertEqual(fixture.audio.prepareCount, 0)
    }

    // While idle, too: a prepared engine is released for sleep and lock.
    let idle = makeFixture()
    idle.coordinator.cancelForSuspension()
    XCTAssertEqual(idle.audio.discardCount, 1)
  }

  func testIdleUserCancelKeepsThePreparedEngine() async throws {
    let fixture = makeFixture()
    fixture.coordinator.cancel()
    try await Task.sleep(for: .milliseconds(20))
    XCTAssertEqual(fixture.audio.discardCount, 0)
    XCTAssertEqual(fixture.audio.prepareCount, 0)
  }

  func testWakeOrUnlockPreparesOnlyWhenIdleAuthorizedAndOnboarded() async throws {
    let notOnboarded = makeFixture()
    notOnboarded.coordinator.prepareAudioIfIdle()

    let unauthorized = makeFixture(readiness: FakeReadiness(microphoneAuthorized: false))
    unauthorized.preferences.onboardingComplete = true
    unauthorized.coordinator.prepareAudioIfIdle()

    let dictating = makeFixture()
    dictating.preferences.onboardingComplete = true
    dictating.coordinator.toggle()
    try await waitUntil { dictating.coordinator.phase == .recording }
    dictating.coordinator.prepareAudioIfIdle()

    let idle = makeFixture()
    idle.preferences.onboardingComplete = true
    idle.coordinator.prepareAudioIfIdle()
    try await waitUntil { idle.audio.prepareCount == 1 }
    XCTAssertFalse(idle.audio.didStart)

    try await Task.sleep(for: .milliseconds(30))
    XCTAssertEqual(notOnboarded.audio.prepareCount, 0)
    XCTAssertEqual(unauthorized.audio.prepareCount, 0)
    XCTAssertEqual(dictating.audio.prepareCount, 0)
    dictating.coordinator.cancel()
  }

  // MARK: - The microphone starts at the press

  func testMicrophoneStartsAtThePressBeforeTheChecks() async throws {
    let fixture = makeFixture(audioStartWaitsForResolution: true)
    fixture.preferences.muteOutput = true
    fixture.coordinator.toggle()
    // Requested inside toggle(), before start() reads credentials or checks permissions.
    XCTAssertEqual(fixture.benchmark.orderedMilestones, [.audioEngineStartRequested])
    try await waitUntil { fixture.audio.hasPendingStart }
    XCTAssertEqual(fixture.audio.startRequestsDecliningBluetooth, [true])
    XCTAssertNil(fixture.audio.discardDeadline)

    fixture.audio.resolveStart(usedPreparation: true)
    try await waitUntil { fixture.coordinator.phase == .recording }
    let expected: [BenchmarkMilestone] = [
      .audioEngineStartRequested, .credentialReadStarted, .credentialsReady,
      .readinessCheckStarted, .readinessChecksFinished, .startCuePlaybackStarted,
      .startCuePlaybackReturned, .startCueDelayFinished, .outputMuteStarted,
      .outputMuteFinished, .preparedAudioEngineUsed, .captureStarted,
    ]
    XCTAssertEqual(fixture.benchmark.orderedMilestones.filter { expected.contains($0) }, expected)
    XCTAssertEqual(fixture.audio.startRequestsDecliningBluetooth, [true])
    // Muting still happens in start(), after the request.
    XCTAssertTrue(fixture.muter.didMute)
    fixture.coordinator.cancel()
  }

  func testAudioRecordedBeforeTheChecksFinishIsKeptForTheDictation() async throws {
    let fixture = makeFixture(audioFrameCount: 2)
    fixture.coordinator.toggle()
    try await waitUntil { fixture.coordinator.phase == .recording }
    fixture.coordinator.toggle()
    try await waitUntil { fixture.coordinator.phase == .success }
    XCTAssertEqual(fixture.benchmark.audioBytes, 6_400)
    XCTAssertEqual(fixture.benchmark.audioBytesSent, 6_400)
  }

  func testFailedCheckAfterAnEarlyStartStopsTheMicrophoneAndSendsNothing() async throws {
    let cases: [(fixture: CoordinatorFixture, category: BenchmarkFailureCategory)] = [
      (makeFixture(hasSonioxKey: false, audioFrameCount: 3), .missingCredential),
      (makeFixture(hasGroqKey: false, cleanupProvider: .groq, audioFrameCount: 3),
       .missingCredential),
      (makeFixture(readiness: FakeReadiness(accessibility: false), audioFrameCount: 3),
       .accessibilityPermission),
      (makeFixture(
        transcriptionProvider: .local, hasSonioxKey: false, hasMetaKey: false,
        audioFrameCount: 3, localReady: false), .unknown),
    ]
    for (fixture, category) in cases {
      fixture.coordinator.toggle()
      XCTAssertTrue(fixture.benchmark.milestones.contains(.audioEngineStartRequested))
      try await waitUntil {
        if case .error = fixture.coordinator.phase { return true }
        return false
      }
      XCTAssertEqual(fixture.benchmark.failureStage, .readiness)
      XCTAssertEqual(fixture.benchmark.failureCategory, category)
      XCTAssertTrue(fixture.notch.presentedStates.contains {
        if case .error = $0.phase { return true }
        return false
      })
      try await assertMicrophoneStoppedAndNothingSent(fixture)
      try await waitUntil { fixture.audio.prepareCount == 1 }
      XCTAssertFalse(fixture.muter.didMute)
    }
  }

  func testCancelRightAfterThePressNeverRecords() async throws {
    let fixture = makeFixture(audioFrameCount: 3)
    fixture.coordinator.toggle()
    fixture.coordinator.cancel()
    try await waitUntil { fixture.coordinator.phase == .idle }
    XCTAssertFalse(fixture.benchmark.milestones.contains(.captureStarted))
    XCTAssertEqual(fixture.benchmark.terminalResult, .cancelled)
    try await assertMicrophoneStoppedAndNothingSent(fixture)
  }

  func testWithoutMicrophonePermissionTheMicrophoneStartsAfterTheChecks() async throws {
    let readiness = SuspendedReadiness()
    let fixture = makeFixture(readiness: readiness)
    fixture.coordinator.toggle()
    try await waitUntil { readiness.didRequestMicrophone }
    XCTAssertFalse(fixture.audio.didStart)
    XCTAssertFalse(fixture.benchmark.milestones.contains(.audioEngineStartRequested))
    readiness.resolveMicrophoneRequest(true)
    try await waitUntil { fixture.coordinator.phase == .recording }
    XCTAssertEqual(fixture.audio.startRequestsDecliningBluetooth, [false])
    fixture.coordinator.cancel()
  }

  func testBluetoothInputStartsAfterTheChecks() async throws {
    let fixture = makeFixture(audioStartDeclines: true)
    fixture.coordinator.toggle()
    try await waitUntil { fixture.coordinator.phase == .recording }
    XCTAssertEqual(fixture.audio.startRequestsDecliningBluetooth, [true, false])
    XCTAssertEqual(fixture.audio.declinedStartCount, 1)
    XCTAssertTrue(fixture.benchmark.milestones.contains(.earlyAudioStartDeclined))
    fixture.coordinator.toggle()
    try await waitUntil { fixture.coordinator.phase == .success }
    XCTAssertEqual(fixture.inserter.insertedText, "Cleaned text.")
  }

  // MARK: - Content-free timings

  func testStartAndStopStepsAreRecorded() async throws {
    let fixture = makeFixture()
    fixture.inserter.insertionSteps = InsertionSteps(
      editorLookup: .milliseconds(7), prePasteProbe: .milliseconds(9),
      revalidation: .milliseconds(10))
    let generation = try XCTUnwrap(
      fixture.coordinator.shortcutPressed(eventAge: .milliseconds(12)))
    try await waitUntil { fixture.coordinator.phase == .recording }
    XCTAssertEqual(fixture.benchmark.steps[.shortcutEventToActivation], .milliseconds(12))
    XCTAssertEqual(fixture.benchmark.steps[.audioQueueWait], .milliseconds(1))
    XCTAssertEqual(fixture.benchmark.steps[.audioRouteCheck], .milliseconds(2))
    XCTAssertEqual(fixture.benchmark.steps[.audioEngineCreate], .milliseconds(3))
    XCTAssertEqual(fixture.benchmark.steps[.audioTapInstall], .milliseconds(4))
    XCTAssertEqual(fixture.benchmark.steps[.audioEnginePrepare], .milliseconds(5))
    XCTAssertEqual(fixture.benchmark.steps[.audioEngineStart], .milliseconds(6))

    fixture.coordinator.finishHeldDictation(lifecycleGeneration: generation)
    XCTAssertNotNil(fixture.benchmark.steps[.audioStop])
    XCTAssertNotNil(fixture.benchmark.steps[.targetPin])
    try await waitUntil { fixture.coordinator.phase == .success }
    XCTAssertEqual(fixture.benchmark.steps[.editorLookup], .milliseconds(7))
    XCTAssertEqual(fixture.benchmark.steps[.prePasteProbe], .milliseconds(9))
    XCTAssertEqual(fixture.benchmark.steps[.pasteRevalidation], .milliseconds(10))
  }

  func testPreparedStartRecordsNoEngineCreationAndAStopPressNoShortcutDelay() async throws {
    let fixture = makeFixture(audioStartWaitsForResolution: true)
    _ = try XCTUnwrap(fixture.coordinator.shortcutPressed())
    try await waitUntil { fixture.audio.hasPendingStart }
    fixture.audio.resolveStart(usedPreparation: true)
    try await waitUntil { fixture.coordinator.phase == .recording }
    XCTAssertNil(fixture.benchmark.steps[.audioEngineCreate])
    XCTAssertNil(fixture.benchmark.steps[.shortcutEventToActivation])
    XCTAssertNil(fixture.coordinator.shortcutPressed(eventAge: .milliseconds(5)))
    XCTAssertNil(fixture.benchmark.steps[.shortcutEventToActivation])
    try await waitUntil { fixture.coordinator.phase == .success }
  }

  private func assertMicrophoneStoppedAndNothingSent(
    _ fixture: CoordinatorFixture, file: StaticString = #filePath, line: UInt = #line
  ) async throws {
    // Let any audio already delivered to the main queue arrive.
    try await Task.sleep(for: .milliseconds(30))
    XCTAssertTrue(fixture.audio.didStop, file: file, line: line)
    XCTAssertFalse(fixture.transcriber.didConnect, file: file, line: line)
    XCTAssertTrue(fixture.transcriber.sentFrames.isEmpty, file: file, line: line)
    XCTAssertEqual(fixture.coordinator.bufferedBytes, 0, file: file, line: line)
    XCTAssertEqual(fixture.benchmark.audioBytesSent, 0, file: file, line: line)
  }
}

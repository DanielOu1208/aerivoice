import Foundation
import XCTest

@testable import AeriVoice

@MainActor
final class DictationCoordinatorBenchmarkTests: XCTestCase {
  func testLaunchPreparationRequiresOnboardingAndExistingMicrophonePermission() async throws {
    let fixture = makeFixture()
    fixture.coordinator.prepareForLaunch(microphoneAuthorized: true)
    fixture.preferences.onboardingComplete = true
    fixture.coordinator.prepareForLaunch(microphoneAuthorized: false)
    XCTAssertEqual(fixture.audio.prepareCount, 0)
    XCTAssertTrue(fixture.credentials.readKinds.isEmpty)

    fixture.coordinator.prepareForLaunch(microphoneAuthorized: true)
    try await waitUntil {
      fixture.audio.prepareCount == 1 && fixture.credentials.readKinds.count == 2
    }
    fixture.coordinator.prepareForLaunch(microphoneAuthorized: true)
    XCTAssertEqual(fixture.audio.prepareCount, 1)
    XCTAssertEqual(fixture.credentials.readKinds, [.soniox, .openRouter])
    XCTAssertFalse(fixture.audio.didStart)
    XCTAssertTrue(fixture.cuePlayer.playedCues.isEmpty)
    XCTAssertTrue(fixture.notch.presentedStates.isEmpty)
    XCTAssertFalse(fixture.transcriber.didConnect)
    XCTAssertEqual(fixture.coordinator.phase, .idle)
    fixture.coordinator.cancel()
    XCTAssertGreaterThan(fixture.audio.discardCount, 0)
  }

  func testActivationReadsFreshCredentialsAfterLaunchPreparation() async throws {
    let fixture = makeFixture(cleanupProvider: .cerebras)
    fixture.preferences.onboardingComplete = true
    fixture.coordinator.prepareForLaunch(microphoneAuthorized: true)
    try await waitUntil { fixture.credentials.readKinds.count == 2 }
    fixture.credentials.setValue("replacement-key", for: .soniox)
    fixture.coordinator.toggle()
    try await waitUntil { fixture.coordinator.phase == .recording }
    XCTAssertEqual(fixture.transcriber.lastAPIKey, "replacement-key")
    XCTAssertEqual(fixture.credentials.readKinds, [.soniox, .cerebras, .soniox, .cerebras])
    fixture.coordinator.cancel()
  }

  func testCancelDuringAudioStartupCannotReviveDictationOrMarkAnotherSession() async throws {
    let fixture = makeFixture(audioStartWaitsForResolution: true)
    fixture.coordinator.toggle()
    try await waitUntil { fixture.audio.hasPendingStart }
    fixture.coordinator.cancel()
    XCTAssertTrue(fixture.audio.didStop)
    XCTAssertEqual(fixture.coordinator.phase, .error("Cancelled"))
    fixture.benchmark.milestones.removeAll()
    fixture.audio.resolveStart(usedPreparation: true)
    try await waitUntil { fixture.audio.startReturned }
    await Task.yield()
    XCTAssertFalse(fixture.transcriber.didConnect)
    XCTAssertFalse(fixture.benchmark.milestones.contains(.captureStarted))
    XCTAssertFalse(fixture.benchmark.milestones.contains(.preparedAudioEngineUsed))
    XCTAssertEqual(fixture.coordinator.phase, .error("Cancelled"))
  }

  func testMetaFailureDuringAudioStartupCancelsTheStartupTask() async throws {
    let fixture = makeFixture(
      transcriptionProvider: .meta, audioStartWaitsForResolution: true)
    fixture.coordinator.toggle()
    try await waitUntil { fixture.audio.hasPendingStart && fixture.transcriber.didConnect }
    fixture.transcriber.emitError(AppError.provider("Meta stream failed"))
    XCTAssertEqual(fixture.benchmark.terminalResult, .failed)
    XCTAssertTrue(fixture.audio.didStop)
    fixture.audio.resolveStart(usedPreparation: true)
    try await waitUntil { fixture.audio.startReturned }
    XCTAssertTrue(fixture.audio.startWasCancelled)
    XCTAssertFalse(fixture.benchmark.milestones.contains(.captureStarted))
    XCTAssertTrue(fixture.transcriber.sentFrames.isEmpty)
  }

  func testHeldReleaseDuringAudioStartupCancelsInsteadOfFinishingUnstartedCapture() async throws {
    let fixture = makeFixture(audioStartWaitsForResolution: true)
    let generation = try XCTUnwrap(fixture.coordinator.shortcutPressed())
    try await waitUntil { fixture.audio.hasPendingStart }
    fixture.coordinator.finishHeldDictation(lifecycleGeneration: generation)
    XCTAssertTrue(fixture.audio.didStop)
    fixture.audio.resolveStart()
    try await waitUntil { fixture.audio.startReturned }
    XCTAssertEqual(fixture.benchmark.terminalResult, .cancelled)
    XCTAssertFalse(fixture.benchmark.milestones.contains(.stopRequested))
    XCTAssertNil(fixture.inserter.insertedText)
  }

  func testStartupTimingsIncludePreparationUseAndPreserveOrdering() async throws {
    let fixture = makeFixture(audioStartWaitsForResolution: true)
    fixture.coordinator.toggle()
    try await waitUntil { fixture.audio.hasPendingStart }
    fixture.audio.resolveStart(usedPreparation: true)
    try await waitUntil { fixture.coordinator.phase == .recording }
    let expected: [BenchmarkMilestone] = [
      .credentialReadStarted, .credentialsReady, .readinessCheckStarted,
      .readinessChecksFinished, .startCuePlaybackStarted, .startCuePlaybackReturned,
      .startCueDelayFinished, .outputMuteStarted, .outputMuteFinished,
      .audioEngineStartRequested, .preparedAudioEngineUsed, .captureStarted, .sttConfigured,
    ]
    XCTAssertEqual(fixture.benchmark.orderedMilestones.filter { expected.contains($0) }, expected)
    fixture.coordinator.cancel()
  }

  func testCancelledInsertionCannotMarkNewSession() async throws {
    let fixture = makeFixture()
    fixture.inserter.suspendInsert = true
    fixture.coordinator.toggle()
    try await waitUntil { fixture.coordinator.phase == .recording }
    fixture.coordinator.toggle()
    try await waitUntil { fixture.inserter.pendingInsert != nil }
    fixture.coordinator.cancel()
    fixture.benchmark.milestones.removeAll()
    fixture.coordinator.toggle()
    try await waitUntil { fixture.coordinator.phase == .recording }
    fixture.inserter.pendingInsert?.resume()
    fixture.inserter.pendingInsert = nil
    try await waitUntil { fixture.inserter.didReturn }
    await Task.yield()
    XCTAssertFalse(fixture.benchmark.milestones.contains(.insertionFinished))
    XCTAssertEqual(fixture.coordinator.phase, .recording)
    fixture.coordinator.cancel()
  }

  func testTargetIsCapturedSynchronouslyAtStopAndNotRecapturedAtInsertion() async throws {
    let fixture = makeFixture()
    let original = TextInsertionTarget { _ in .pasteSent }
    fixture.inserter.target = original
    fixture.coordinator.toggle()
    try await waitUntil { fixture.coordinator.phase == .recording }
    XCTAssertEqual(fixture.inserter.captureCount, 0)
    fixture.inserter.onCapture = { XCTAssertTrue(fixture.audio.didStop) }
    fixture.coordinator.toggle()
    XCTAssertEqual(fixture.inserter.captureCount, 1)
    fixture.inserter.target = TextInsertionTarget { _ in .pasteSent }
    try await waitUntil { fixture.coordinator.phase == .success }
    XCTAssertEqual(fixture.inserter.receivedTarget?.id, original.id)
    XCTAssertEqual(fixture.inserter.captureCount, 1)
  }

  func testCancellationCancelsTargetAcquisitionAndNeverInserts() async throws {
    let fixture = makeFixture()
    fixture.inserter.suspendCapture = true
    fixture.coordinator.toggle()
    try await waitUntil { fixture.coordinator.phase == .recording }
    fixture.coordinator.toggle()
    try await waitUntil { fixture.coordinator.phase == .inserting }
    fixture.coordinator.cancel()
    try await waitUntil { fixture.inserter.captureCancelled }
    XCTAssertNil(fixture.inserter.insertedText)
    XCTAssertEqual(fixture.benchmark.terminalResult, .cancelled)
  }

  func testPasteSentDoesNotClaimConfirmedInsertion() async throws {
    let fixture = makeFixture()
    fixture.inserter.result = .pasteSent
    fixture.coordinator.toggle()
    try await waitUntil { fixture.coordinator.phase == .recording }
    fixture.coordinator.toggle()
    try await waitUntil { fixture.coordinator.phase == .success }
    XCTAssertEqual(fixture.benchmark.terminalResult, .pasteSent)
    XCTAssertNil(fixture.notch.presentedStates.last?.warning)
    XCTAssertEqual(fixture.notch.hideDelays.last, .milliseconds(700))
  }

  func testSecureFieldCopiesWithSpecificWarningAndBenchmarkReason() async throws {
    let fixture = makeFixture()
    fixture.inserter.result = .copied(.secureField)
    fixture.coordinator.toggle()
    try await waitUntil { fixture.coordinator.phase == .recording }
    fixture.coordinator.toggle()
    try await waitUntil {
      fixture.coordinator.phase == .error(PasteBlockReason.secureField.copiedMessage)
    }
    XCTAssertEqual(fixture.benchmark.terminalResult, .copied)
    XCTAssertEqual(fixture.benchmark.failureStage, .insertion)
    XCTAssertEqual(fixture.benchmark.failureCategory, .secureField)
    XCTAssertEqual(
      fixture.notch.presentedStates.last?.warning, PasteBlockReason.secureField.copiedMessage)
  }

  func testCopyFailureIsNotLoggedAsCopied() async throws {
    let fixture = makeFixture()
    fixture.inserter.result = .failed("Clipboard changed")
    fixture.coordinator.toggle()
    try await waitUntil { fixture.coordinator.phase == .recording }
    fixture.coordinator.toggle()
    try await waitUntil { fixture.coordinator.phase == .error("Clipboard changed") }
    XCTAssertEqual(fixture.benchmark.terminalResult, .failed)
    XCTAssertEqual(fixture.benchmark.failureStage, .insertion)
  }

  func testSuccessfulDictationRecordsPipelineMilestones() async throws {
    let fixture = makeFixture()
    fixture.coordinator.toggle()
    try await waitUntil { fixture.coordinator.phase == .recording }

    fixture.coordinator.toggle()
    try await waitUntil { fixture.coordinator.phase == .success }

    XCTAssertTrue(fixture.benchmark.didBegin)
    XCTAssertTrue(fixture.benchmark.milestones.contains(.captureStarted))
    XCTAssertTrue(fixture.benchmark.milestones.contains(.sttConfigured))
    XCTAssertTrue(fixture.benchmark.milestones.contains(.firstAudioCaptured) == false)
    XCTAssertEqual(fixture.benchmark.audioBytes, 3_200)
    XCTAssertEqual(fixture.benchmark.audioBytesSent, 3_200)
    XCTAssertEqual(fixture.benchmark.sttUpdates, 2)
    XCTAssertTrue(fixture.benchmark.milestones.contains(.stopRequested))
    XCTAssertTrue(fixture.benchmark.milestones.contains(.audioCallbacksFlushed))
    XCTAssertTrue(fixture.benchmark.milestones.contains(.audioQueueDrained))
    XCTAssertTrue(fixture.benchmark.milestones.contains(.sttFinalizeStarted))
    XCTAssertTrue(fixture.benchmark.milestones.contains(.sttFinalized))
    XCTAssertTrue(fixture.benchmark.milestones.contains(.cleanupStarted))
    XCTAssertTrue(fixture.benchmark.milestones.contains(.cleanupFinished))
    XCTAssertTrue(fixture.benchmark.milestones.contains(.insertionStarted))
    XCTAssertTrue(fixture.benchmark.milestones.contains(.insertionFinished))
    XCTAssertEqual(fixture.benchmark.rawCharacters, 14)
    XCTAssertEqual(fixture.benchmark.cleanedCharacters, 13)
    XCTAssertEqual(fixture.benchmark.cleanupMetrics?.selectedProvider, "Test Provider")
    XCTAssertEqual(fixture.benchmark.terminalResult, .pasteSent)
    XCTAssertEqual(fixture.inserter.insertedText, "Cleaned text.")
  }

  func testCleanupFailureRecordsRawFallbackAndStillInsertsRawText() async throws {
    let fixture = makeFixture(
      cleanupError: ProviderHTTPError(statusCode: 503, message: "SECRET_PROVIDER_ERROR"))
    fixture.coordinator.toggle()
    try await waitUntil { fixture.coordinator.phase == .recording }

    fixture.coordinator.toggle()
    try await waitUntil { fixture.coordinator.phase == .success }

    XCTAssertEqual(fixture.inserter.insertedText, "Raw transcript")
    XCTAssertEqual(fixture.benchmark.cleanupFallbackStatus, 503)
    XCTAssertEqual(fixture.benchmark.cleanedCharacters, 14)
    XCTAssertEqual(fixture.benchmark.terminalResult, .pasteSent)
  }

  func testMissingCredentialRecordsReadinessFailure() async throws {
    let fixture = makeFixture(hasSonioxKey: false)

    fixture.coordinator.toggle()
    try await waitUntil {
      if case .error = fixture.coordinator.phase { return true }
      return false
    }

    XCTAssertTrue(fixture.benchmark.didBegin)
    XCTAssertEqual(fixture.benchmark.terminalResult, .failed)
    XCTAssertEqual(fixture.benchmark.failureStage, .readiness)
    XCTAssertEqual(fixture.benchmark.failureCategory, .missingCredential)
    XCTAssertFalse(fixture.audio.didStart)
  }

  func testSelectedGroqProviderUsesGroqCredential() async throws {
    let fixture = makeFixture(cleanupProvider: .groq)

    fixture.coordinator.toggle()
    try await waitUntil { fixture.coordinator.phase == .recording }
    fixture.coordinator.toggle()
    try await waitUntil { fixture.coordinator.phase == .success }

    XCTAssertEqual(fixture.cleaner.lastConfiguration?.provider, .groq)
    XCTAssertEqual(fixture.cleaner.lastAPIKey, "groq-key")
  }

  func testMissingSelectedGroqCredentialFailsBeforeAudioCapture() async throws {
    let fixture = makeFixture(hasGroqKey: false, cleanupProvider: .groq)

    fixture.coordinator.toggle()
    try await waitUntil {
      if case .error = fixture.coordinator.phase { return true }
      return false
    }

    XCTAssertEqual(fixture.benchmark.failureCategory, .missingCredential)
    XCTAssertFalse(fixture.audio.didStart)
  }

  func testSelectedCerebrasProviderUsesCerebrasCredential() async throws {
    let fixture = makeFixture(cleanupProvider: .cerebras)

    fixture.coordinator.toggle()
    try await waitUntil { fixture.coordinator.phase == .recording }
    try await waitUntil { fixture.cleaner.didRequestWarmUp }
    fixture.coordinator.toggle()
    try await waitUntil { fixture.coordinator.phase == .success }

    XCTAssertEqual(fixture.cleaner.lastWarmUpConfiguration?.provider, .cerebras)
    XCTAssertEqual(fixture.cleaner.lastWarmUpAPIKey, "cerebras-key")
    XCTAssertEqual(fixture.cleaner.lastConfiguration?.provider, .cerebras)
    XCTAssertEqual(fixture.cleaner.lastAPIKey, "cerebras-key")
  }

  func testCerebrasWarmUpDoesNotDelayRecording() async throws {
    let fixture = makeFixture(cleanupProvider: .cerebras, warmUpWaitsForResolution: true)

    fixture.coordinator.toggle()
    try await waitUntil { fixture.cleaner.didRequestWarmUp }
    try await waitUntil { fixture.coordinator.phase == .recording }

    XCTAssertTrue(fixture.audio.didStart)
    fixture.cleaner.resolveWarmUp()
    fixture.coordinator.cancel()
  }

  func testNonCerebrasProviderDoesNotWarmUp() async throws {
    let fixture = makeFixture(cleanupProvider: .openRouter)

    fixture.coordinator.toggle()
    try await waitUntil { fixture.coordinator.phase == .recording }
    await Task.yield()

    XCTAssertFalse(fixture.cleaner.didRequestWarmUp)
    fixture.coordinator.cancel()
  }

  func testMissingSelectedCerebrasCredentialFailsBeforeAudioCapture() async throws {
    let fixture = makeFixture(hasCerebrasKey: false, cleanupProvider: .cerebras)

    fixture.coordinator.toggle()
    try await waitUntil {
      if case .error = fixture.coordinator.phase { return true }
      return false
    }

    XCTAssertEqual(fixture.benchmark.failureCategory, .missingCredential)
    XCTAssertFalse(fixture.audio.didStart)
  }

  func testSelectedMetaProviderUsesMetaCredentialAndConfiguration() async throws {
    let fixture = makeFixture(transcriptionProvider: .meta)

    fixture.coordinator.toggle()
    try await waitUntil { fixture.coordinator.phase == .recording }

    XCTAssertEqual(
      fixture.transcriber.lastConfiguration, TranscriptionConfiguration(provider: .meta))
    XCTAssertEqual(fixture.transcriber.lastAPIKey, "meta-key")
    XCTAssertEqual(fixture.transcriber.lastVocabulary, ["AeriVoice"])
    XCTAssertEqual(fixture.benchmark.transcriptionConfiguration?.provider, .meta)
    fixture.coordinator.cancel()
  }

  func testMetaConnectsDuringCueWithoutDelayingCapture() async throws {
    let fixture = makeFixture(
      transcriptionProvider: .meta, soundCues: true, cueDelay: .milliseconds(20),
      connectWaitsForResolution: true)

    fixture.coordinator.toggle()
    try await waitUntil { fixture.transcriber.didConnect }

    XCTAssertEqual(fixture.cuePlayer.playedCues, [.start])
    try await waitUntil { fixture.audio.didStart }
    XCTAssertEqual(fixture.coordinator.phase, .recording)
    XCTAssertEqual(fixture.benchmark.audioBytes, 3_200)
    XCTAssertEqual(fixture.benchmark.audioBytesSent, 0)

    fixture.transcriber.resolveConnect()
    try await waitUntil { fixture.benchmark.audioBytesSent == 3_200 }

    fixture.coordinator.cancel()
  }

  func testMetaCatchUpReceivesRemainingQueueDepthForEveryBufferedFrame() async throws {
    let fixture = makeFixture(
      transcriptionProvider: .meta, connectWaitsForResolution: true, audioFrameCount: 3)
    fixture.coordinator.toggle()
    try await waitUntil { fixture.benchmark.audioBytes == 9_600 }

    XCTAssertTrue(fixture.transcriber.sentFrames.isEmpty)
    fixture.transcriber.resolveConnect()
    try await waitUntil { fixture.transcriber.sentFrames.count == 3 }

    XCTAssertEqual(
      fixture.transcriber.sentFrames.map(\.queuedBytesAfterFrame), [6_400, 3_200, 0])
    XCTAssertEqual(fixture.benchmark.audioBytesSent, 9_600)
    fixture.coordinator.cancel()
  }

  func testSonioxStillStartsCaptureBeforeConnecting() async throws {
    let fixture = makeFixture(connectWaitsForResolution: true)

    fixture.coordinator.toggle()
    try await waitUntil { fixture.transcriber.didConnect }

    XCTAssertTrue(fixture.audio.didStart)
    XCTAssertEqual(fixture.benchmark.audioBytes, 3_200)
    XCTAssertEqual(fixture.benchmark.audioBytesSent, 0)

    fixture.transcriber.resolveConnect()
    try await waitUntil { fixture.coordinator.phase == .recording }
    XCTAssertEqual(fixture.benchmark.audioBytesSent, 3_200)
    fixture.coordinator.cancel()
  }

  func testCancellingWhileMetaConnectsNeverStartsCapture() async throws {
    let fixture = makeFixture(
      transcriptionProvider: .meta, soundCues: true, cueDelay: .milliseconds(80),
      connectWaitsForResolution: true)
    fixture.coordinator.toggle()
    try await waitUntil { fixture.transcriber.didConnect }

    fixture.coordinator.toggle()
    try await waitUntil { fixture.benchmark.terminalResult == .cancelled }

    XCTAssertFalse(fixture.audio.didStart)
    XCTAssertFalse(fixture.muter.didMute)
    XCTAssertTrue(fixture.transcriber.didCancel)
  }

  func testHeldReleaseWhileMetaConnectsNeverStartsCapture() async throws {
    let fixture = makeFixture(
      transcriptionProvider: .meta, soundCues: true, cueDelay: .milliseconds(80),
      connectWaitsForResolution: true)
    let lifecycleGeneration = try XCTUnwrap(fixture.coordinator.shortcutPressed())
    try await waitUntil { fixture.transcriber.didConnect }

    fixture.coordinator.finishHeldDictation(lifecycleGeneration: lifecycleGeneration)
    try await waitUntil { fixture.benchmark.terminalResult == .cancelled }

    XCTAssertFalse(fixture.audio.didStart)
    XCTAssertFalse(fixture.muter.didMute)
    XCTAssertTrue(fixture.transcriber.didCancel)
  }

  func testMetaConnectionFailureNeverStartsCapture() async throws {
    let fixture = makeFixture(
      transcriptionProvider: .meta, soundCues: true, cueDelay: .milliseconds(80),
      connectError: AppError.provider("Meta connection failed"))

    fixture.coordinator.toggle()
    try await waitUntil { fixture.benchmark.terminalResult == .failed }

    XCTAssertEqual(fixture.benchmark.failureStage, .sttSetup)
    XCTAssertFalse(fixture.audio.didStart)
    XCTAssertFalse(fixture.muter.didMute)
  }

  func testMetaProviderErrorDuringCueIsClassifiedAsSetupFailure() async throws {
    let fixture = makeFixture(
      transcriptionProvider: .meta, soundCues: true, cueDelay: .milliseconds(80))
    fixture.coordinator.toggle()
    try await waitUntil { fixture.cuePlayer.playedCues == [.start] }

    fixture.transcriber.emitError(AppError.provider("Meta stream failed"))
    try await waitUntil { fixture.benchmark.terminalResult == .failed }
    try await Task.sleep(for: .milliseconds(100))

    XCTAssertEqual(fixture.benchmark.failureStage, .sttSetup)
    XCTAssertFalse(fixture.audio.didStart)
    XCTAssertFalse(fixture.muter.didMute)
  }

  func testCompletedMetaDictationRecordsStopDrainAndFinalizeMilestones() async throws {
    let fixture = makeFixture(transcriptionProvider: .meta)
    fixture.coordinator.toggle()
    try await waitUntil { fixture.coordinator.phase == .recording }

    fixture.coordinator.toggle()
    try await waitUntil { fixture.coordinator.phase == .success }

    XCTAssertTrue(fixture.benchmark.milestones.contains(.audioCallbacksFlushed))
    XCTAssertTrue(fixture.benchmark.milestones.contains(.audioQueueDrained))
    XCTAssertTrue(fixture.benchmark.milestones.contains(.sttFinalizeStarted))
    XCTAssertTrue(fixture.benchmark.milestones.contains(.sttFinalized))
    XCTAssertEqual(fixture.benchmark.audioBytesSent, 3_200)
  }

  func testStoppingWhileMetaConnectsWaitsThenDrainsAllCapturedAudio() async throws {
    let fixture = makeFixture(
      transcriptionProvider: .meta, connectWaitsForResolution: true, audioFrameCount: 3)
    fixture.coordinator.toggle()
    try await waitUntil { fixture.coordinator.phase == .recording }

    fixture.coordinator.toggle()
    try await waitUntil { fixture.audio.didStop }
    fixture.transcriber.resolveConnect()
    try await waitUntil { fixture.coordinator.phase == .success }

    XCTAssertEqual(fixture.transcriber.sentFrames.count, 3)
    XCTAssertEqual(fixture.benchmark.audioBytesSent, 9_600)
    XCTAssertTrue(fixture.benchmark.milestones.contains(.audioQueueDrained))
  }

  func testMissingSelectedMetaCredentialDoesNotFallBackToSoniox() async throws {
    let fixture = makeFixture(
      transcriptionProvider: .meta, hasSonioxKey: true, hasMetaKey: false)

    fixture.coordinator.toggle()
    try await waitUntil {
      if case .error = fixture.coordinator.phase { return true }
      return false
    }

    XCTAssertEqual(fixture.benchmark.failureCategory, .missingCredential)
    XCTAssertFalse(fixture.transcriber.didConnect)
    XCTAssertFalse(fixture.audio.didStart)
  }

  func testTranscriptionProviderIsSnapshottedWhenDictationBegins() async throws {
    let readiness = SuspendedReadiness()
    let fixture = makeFixture(transcriptionProvider: .meta, readiness: readiness)
    fixture.coordinator.toggle()
    try await waitUntil { readiness.didRequestMicrophone }

    fixture.preferences.transcriptionProvider = .soniox
    readiness.resolveMicrophoneRequest(true)
    try await waitUntil { fixture.coordinator.phase == .recording }

    XCTAssertEqual(fixture.transcriber.lastConfiguration?.provider, .meta)
    XCTAssertEqual(fixture.transcriber.lastAPIKey, "meta-key")
    fixture.coordinator.cancel()
  }

  func testCancellationRecordsTerminalCancellation() async throws {
    let fixture = makeFixture()
    fixture.coordinator.toggle()
    try await waitUntil { fixture.coordinator.phase == .recording }

    fixture.coordinator.cancel()

    XCTAssertEqual(fixture.benchmark.terminalResult, .cancelled)
    XCTAssertEqual(fixture.benchmark.failureStage, .lifecycle)
    XCTAssertEqual(fixture.benchmark.failureCategory, .cancelled)
    XCTAssertTrue(fixture.transcriber.didCancel)
    XCTAssertTrue(fixture.audio.didStop)
  }

  func testStoppingDuringCueDelayCancelsBeforeCaptureStarts() async throws {
    let fixture = makeFixture(soundCues: true, cueDelay: .milliseconds(80))
    fixture.coordinator.toggle()
    try await waitUntil { fixture.cuePlayer.playedCues == [.start] }

    fixture.coordinator.toggle()
    try await waitUntil { fixture.benchmark.terminalResult == .cancelled }
    try await Task.sleep(for: .milliseconds(120))

    XCTAssertFalse(fixture.audio.didStart)
    XCTAssertFalse(fixture.muter.didMute)
    XCTAssertFalse(fixture.transcriber.didConnect)
  }

  func testHeldShortcutReleaseStopsSessionStartedByPress() async throws {
    let fixture = makeFixture()

    let lifecycleGeneration = try XCTUnwrap(fixture.coordinator.shortcutPressed())
    try await waitUntil { fixture.coordinator.phase == .recording }
    fixture.coordinator.finishHeldDictation(lifecycleGeneration: lifecycleGeneration)
    try await waitUntil { fixture.coordinator.phase == .success }

    XCTAssertEqual(fixture.benchmark.terminalResult, .pasteSent)
    XCTAssertEqual(fixture.inserter.insertedText, "Cleaned text.")
  }

  func testPressWhileRecordingStopsAndReleaseCannotRestart() async throws {
    let fixture = makeFixture()

    let lifecycleGeneration = try XCTUnwrap(fixture.coordinator.shortcutPressed())
    try await waitUntil { fixture.coordinator.phase == .recording }
    XCTAssertNil(fixture.coordinator.shortcutPressed())
    try await waitUntil { fixture.coordinator.phase == .success }

    fixture.coordinator.finishHeldDictation(lifecycleGeneration: lifecycleGeneration)
    await Task.yield()

    XCTAssertEqual(fixture.coordinator.phase, .success)
    XCTAssertEqual(fixture.benchmark.terminalResult, .pasteSent)
  }

  func testOldHeldReleaseCannotStopNewerMenuStartedSession() async throws {
    let fixture = makeFixture()
    let oldLifecycleGeneration = try XCTUnwrap(fixture.coordinator.shortcutPressed())
    try await waitUntil { fixture.coordinator.phase == .recording }
    fixture.coordinator.toggle()
    try await waitUntil { fixture.coordinator.phase == .success }

    fixture.coordinator.toggle()
    try await waitUntil { fixture.coordinator.phase == .recording }
    fixture.coordinator.finishHeldDictation(lifecycleGeneration: oldLifecycleGeneration)
    await Task.yield()

    XCTAssertEqual(fixture.coordinator.phase, .recording)
    fixture.coordinator.cancel()
  }

  func testHeldReleaseDuringCueDelayCancelsBeforeCaptureStarts() async throws {
    let fixture = makeFixture(soundCues: true, cueDelay: .milliseconds(80))
    let lifecycleGeneration = try XCTUnwrap(fixture.coordinator.shortcutPressed())
    try await waitUntil { fixture.cuePlayer.playedCues == [.start] }

    fixture.coordinator.finishHeldDictation(lifecycleGeneration: lifecycleGeneration)
    try await waitUntil { fixture.benchmark.terminalResult == .cancelled }
    try await Task.sleep(for: .milliseconds(120))

    XCTAssertFalse(fixture.audio.didStart)
    XCTAssertFalse(fixture.muter.didMute)
    XCTAssertFalse(fixture.transcriber.didConnect)
  }

  func testHeldReleaseAfterStartupFailureCannotRestart() async throws {
    let fixture = makeFixture(hasSonioxKey: false)
    let lifecycleGeneration = try XCTUnwrap(fixture.coordinator.shortcutPressed())
    try await waitUntil {
      if case .error = fixture.coordinator.phase { return true }
      return false
    }

    fixture.coordinator.finishHeldDictation(lifecycleGeneration: lifecycleGeneration)
    await Task.yield()

    guard case .error = fixture.coordinator.phase else {
      XCTFail("Held release changed a failed startup phase")
      return
    }
    XCTAssertFalse(fixture.audio.didStart)
    XCTAssertEqual(fixture.benchmark.failureCategory, .missingCredential)
  }

  func testCancellationWhileMicrophoneReadinessIsSuspendedNeverStartsCapture() async throws {
    let readiness = SuspendedReadiness()
    let fixture = makeFixture(readiness: readiness)
    fixture.coordinator.toggle()
    try await waitUntil { readiness.didRequestMicrophone }

    fixture.coordinator.cancel()
    readiness.resolveMicrophoneRequest(true)
    try await waitUntil { fixture.benchmark.terminalResult == .cancelled }
    try await Task.sleep(for: .milliseconds(20))

    XCTAssertFalse(fixture.audio.didStart)
    XCTAssertFalse(fixture.muter.didMute)
    XCTAssertFalse(fixture.transcriber.didConnect)
  }

  func testHeldReleaseWhileMicrophoneReadinessIsSuspendedNeverStartsCapture() async throws {
    let readiness = SuspendedReadiness()
    let fixture = makeFixture(readiness: readiness)
    let lifecycleGeneration = try XCTUnwrap(fixture.coordinator.shortcutPressed())
    try await waitUntil { readiness.didRequestMicrophone }

    fixture.coordinator.finishHeldDictation(lifecycleGeneration: lifecycleGeneration)
    readiness.resolveMicrophoneRequest(true)
    try await waitUntil { fixture.benchmark.terminalResult == .cancelled }
    try await Task.sleep(for: .milliseconds(20))

    XCTAssertFalse(fixture.audio.didStart)
    XCTAssertFalse(fixture.muter.didMute)
    XCTAssertFalse(fixture.transcriber.didConnect)
  }

  func testCancellationDuringCleanupDoesNotPresentAfterSchedulingHide() async throws {
    let fixture = makeFixture(cleanupWaitsForCancellation: true)
    fixture.coordinator.toggle()
    try await waitUntil { fixture.coordinator.phase == .recording }

    fixture.coordinator.toggle()
    try await waitUntil { fixture.coordinator.phase == .cleaning }
    let presentationCountBeforeCancellation = fixture.notch.presentedStates.count

    fixture.coordinator.cancel()
    try await waitUntil { fixture.cleaner.hasExited }
    await Task.yield()

    XCTAssertEqual(
      fixture.notch.presentedStates.count, presentationCountBeforeCancellation + 1)
    XCTAssertEqual(fixture.notch.presentedStates.last?.phase, .error("Cancelled"))
    XCTAssertEqual(fixture.notch.hideDelays, [.milliseconds(600)])
  }

  func testWhitespaceOnlyUpdateDoesNotCountAsFirstTranscript() async throws {
    let fixture = makeFixture(provisionalText: "  \n")
    fixture.coordinator.toggle()
    try await waitUntil { fixture.benchmark.lastSTTUpdate != nil }

    XCTAssertEqual(fixture.benchmark.lastSTTUpdate?.hasTranscript, false)
    fixture.coordinator.cancel()
  }

  func testCleanupSettingsAreSnapshottedForEachDictation() async throws {
    let fixture = makeFixture()
    fixture.coordinator.toggle()
    try await waitUntil { fixture.coordinator.phase == .recording }

    fixture.preferences.cleanupModel = .gpt56LunaFast
    fixture.preferences.cleanupReasoningEffort = .max
    fixture.preferences.cleanupMode = .polished
    fixture.coordinator.toggle()
    try await waitUntil { fixture.coordinator.phase == .success }

    XCTAssertEqual(
      fixture.cleaner.lastConfiguration,
      CleanupConfiguration(model: .gemini35FlashLite, reasoningEffort: .minimal))
    XCTAssertEqual(fixture.cleaner.lastMode, .faithful)

    fixture.coordinator.toggle()
    try await waitUntil { fixture.coordinator.phase == .recording }
    fixture.coordinator.toggle()
    try await waitUntil { fixture.coordinator.phase == .success }

    XCTAssertEqual(
      fixture.cleaner.lastConfiguration,
      CleanupConfiguration(model: .gpt56LunaFast, reasoningEffort: .max))
    XCTAssertEqual(fixture.cleaner.lastMode, .polished)
  }

  private func makeFixture(
    transcriptionProvider: TranscriptionProvider = .soniox,
    hasSonioxKey: Bool = true, hasMetaKey: Bool = true, hasGroqKey: Bool = true,
    hasCerebrasKey: Bool = true,
    cleanupProvider: CleanupProvider = .openRouter, cleanupError: ProviderHTTPError? = nil,
    provisionalText: String = "Raw", cleanupWaitsForCancellation: Bool = false,
    warmUpWaitsForResolution: Bool = false,
    soundCues: Bool = false, cueDelay: Duration = .zero,
    readiness: DictationReadinessChecking? = nil, connectWaitsForResolution: Bool = false,
    connectError: Error? = nil, audioFrameCount: Int = 1,
    audioStartWaitsForResolution: Bool = false
  ) -> CoordinatorFixture {
    let suite = "AeriVoiceTests.Coordinator.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    defaults.set(soundCues, forKey: "soundCues")
    defaults.set(false, forKey: "muteOutput")
    defaults.set(true, forKey: "latencyLogging")
    let preferences = AppPreferences(defaults: defaults)
    preferences.transcriptionProvider = transcriptionProvider
    preferences.cleanupProvider = cleanupProvider
    preferences.vocabulary = "AeriVoice"
    let credentials = FakeCredentialReader(
      values: [
        .soniox: hasSonioxKey ? "soniox-key" : nil,
        .metaModelAPI: hasMetaKey ? "meta-key" : nil,
        .openRouter: "openrouter-key",
        .groq: hasGroqKey ? "groq-key" : nil,
        .cerebras: hasCerebrasKey ? "cerebras-key" : nil,
      ])
    let audio = FakeAudioCapture(
      frameCount: audioFrameCount, waitsForStartResolution: audioStartWaitsForResolution)
    let transcriber = FakeTranscriber(
      provisionalText: provisionalText, waitsForConnectResolution: connectWaitsForResolution,
      connectError: connectError)
    let cleaner = FakeCleaner(
      error: cleanupError, waitsForCancellation: cleanupWaitsForCancellation,
      warmUpWaitsForResolution: warmUpWaitsForResolution)
    let inserter = FakeInserter()
    let benchmark = BenchmarkSpy()
    let notch = FakeNotch()
    let muter = FakeMuter()
    let cuePlayer = FakeCuePlayer(startCaptureDelay: cueDelay)
    let coordinator = DictationCoordinator(
      preferences: preferences, credentials: credentials, audio: audio,
      transcriber: transcriber, cleaner: cleaner, muter: muter, inserter: inserter,
      notch: notch, benchmark: benchmark, readiness: readiness ?? FakeReadiness(),
      cuePlayer: cuePlayer)
    return CoordinatorFixture(
      preferences: preferences, coordinator: coordinator, audio: audio, transcriber: transcriber,
      inserter: inserter, cleaner: cleaner, muter: muter, notch: notch, benchmark: benchmark,
      cuePlayer: cuePlayer, credentials: credentials, defaultsSuite: suite)
  }

  private func waitUntil(
    timeout: Duration = .seconds(1), _ condition: @escaping @MainActor () -> Bool
  ) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !condition(), clock.now < deadline {
      try await Task.sleep(for: .milliseconds(5))
    }
    XCTAssertTrue(condition(), "Timed out waiting for coordinator state")
  }
}

@MainActor
private struct CoordinatorFixture {
  let preferences: AppPreferences
  let coordinator: DictationCoordinator
  let audio: FakeAudioCapture
  let transcriber: FakeTranscriber
  let inserter: FakeInserter
  let cleaner: FakeCleaner
  let muter: FakeMuter
  let notch: FakeNotch
  let benchmark: BenchmarkSpy
  let cuePlayer: FakeCuePlayer
  let credentials: FakeCredentialReader
  let defaultsSuite: String
}

private final class FakeCredentialReader: CredentialReading, @unchecked Sendable {
  private let lock = NSLock()
  private var values: [CredentialKind: String?]
  private var reads: [CredentialKind] = []
  init(values: [CredentialKind: String?]) { self.values = values }
  var readKinds: [CredentialKind] { lock.withLock { reads } }
  func value(for kind: CredentialKind) -> String? {
    lock.withLock {
      reads.append(kind)
      return values[kind] ?? nil
    }
  }
  func setValue(_ value: String, for kind: CredentialKind) {
    lock.withLock { values[kind] = value }
  }
}

private struct FakeReadiness: DictationReadinessChecking {
  func requestMicrophone() async -> Bool { true }
  func accessibilityReady(prompt: Bool) -> Bool { true }
}

@MainActor
private final class SuspendedReadiness: DictationReadinessChecking {
  private var microphoneContinuation: CheckedContinuation<Bool, Never>?
  private(set) var didRequestMicrophone = false

  func requestMicrophone() async -> Bool {
    didRequestMicrophone = true
    return await withCheckedContinuation { microphoneContinuation = $0 }
  }

  func accessibilityReady(prompt: Bool) -> Bool { true }

  func resolveMicrophoneRequest(_ result: Bool) {
    microphoneContinuation?.resume(returning: result)
    microphoneContinuation = nil
  }
}

private final class FakeAudioCapture: AudioCapturing, @unchecked Sendable {
  private let lock = NSLock()
  private var callback: ((Data) -> Void)?
  private var started = false
  private var stopped = false
  private var returned = false
  private var cancelled = false
  private var preparations = 0
  private var discards = 0
  private var startContinuation: CheckedContinuation<Bool, Never>?
  private let frameCount: Int
  private let waitsForStartResolution: Bool

  init(frameCount: Int, waitsForStartResolution: Bool) {
    self.frameCount = frameCount
    self.waitsForStartResolution = waitsForStartResolution
  }

  var onAudio: ((Data) -> Void)? {
    get { lock.withLock { callback } }
    set { lock.withLock { callback = newValue } }
  }
  var didStart: Bool { lock.withLock { started } }
  var didStop: Bool { lock.withLock { stopped } }
  var startReturned: Bool { lock.withLock { returned } }
  var startWasCancelled: Bool { lock.withLock { cancelled } }
  var prepareCount: Int { lock.withLock { preparations } }
  var discardCount: Int { lock.withLock { discards } }
  var hasPendingStart: Bool { lock.withLock { startContinuation != nil } }

  func prepare() async { lock.withLock { preparations += 1 } }
  func discardPreparation() { lock.withLock { discards += 1 } }

  func start() async throws -> Bool {
    defer { lock.withLock { returned = true } }
    lock.withLock { started = true }
    let reused: Bool
    if waitsForStartResolution {
      reused = await withCheckedContinuation { continuation in
        lock.withLock { startContinuation = continuation }
      }
    } else {
      reused = false
    }
    let wasCancelled = Task.isCancelled
    lock.withLock { cancelled = wasCancelled }
    try Task.checkCancellation()
    for _ in 0..<frameCount {
      onAudio?(Data(repeating: 0, count: 3_200))
    }
    return reused
  }

  func resolveStart(usedPreparation: Bool = false) {
    let continuation = lock.withLock {
      let continuation = startContinuation
      startContinuation = nil
      return continuation
    }
    continuation?.resume(returning: usedPreparation)
  }

  func cancelStart() { lock.withLock { stopped = true } }
  func stop() { lock.withLock { stopped = true } }
}

@MainActor
private final class FakeTranscriber: RealtimeTranscribing {
  var onTranscript: ((RealtimeTranscriptUpdate) -> Void)?
  var onError: ((Error) -> Void)?
  var didCancel = false
  var didConnect = false
  var lastConfiguration: TranscriptionConfiguration?
  var lastAPIKey: String?
  var lastVocabulary: [String] = []
  private(set) var sentFrames: [RealtimeAudioFrame] = []
  private var sentFirstUpdate = false
  private let provisionalText: String
  private let waitsForConnectResolution: Bool
  private let connectError: Error?
  private var connectContinuation: CheckedContinuation<Void, Never>?

  init(provisionalText: String, waitsForConnectResolution: Bool, connectError: Error?) {
    self.provisionalText = provisionalText
    self.waitsForConnectResolution = waitsForConnectResolution
    self.connectError = connectError
  }

  func connect(
    configuration: TranscriptionConfiguration, apiKey: String, vocabulary: [String],
    sessionID: DictationSessionID
  ) async throws {
    didConnect = true
    lastConfiguration = configuration
    lastAPIKey = apiKey
    lastVocabulary = vocabulary
    if waitsForConnectResolution {
      await withCheckedContinuation { connectContinuation = $0 }
    }
    if let connectError { throw connectError }
  }

  func resolveConnect() {
    connectContinuation?.resume()
    connectContinuation = nil
  }

  func emitError(_ error: Error) { onError?(error) }

  func send(_ frame: RealtimeAudioFrame) async throws {
    sentFrames.append(frame)
    guard !sentFirstUpdate else { return }
    sentFirstUpdate = true
    onTranscript?(
      RealtimeTranscriptUpdate(
        snapshot: TranscriptSnapshot(provisional: provisionalText), hasFinalText: false,
        finalAudioProcessedMS: 0, totalAudioProcessedMS: 100))
  }

  func finish() async throws -> String {
    onTranscript?(
      RealtimeTranscriptUpdate(
        snapshot: TranscriptSnapshot(confirmed: "Raw transcript"), hasFinalText: true,
        finalAudioProcessedMS: 100, totalAudioProcessedMS: 100))
    return "Raw transcript"
  }

  func cancel() {
    didCancel = true
    resolveConnect()
  }
}

private final class FakeCleaner: CleaningText, @unchecked Sendable {
  let error: ProviderHTTPError?
  let waitsForCancellation: Bool
  let warmUpWaitsForResolution: Bool
  private let lock = NSLock()
  private var exited = false
  private var recordedConfiguration: CleanupConfiguration?
  private var recordedMode: CleanupMode?
  private var recordedAPIKey: String?
  private var recordedWarmUpConfiguration: CleanupConfiguration?
  private var recordedWarmUpAPIKey: String?
  private var warmUpContinuation: CheckedContinuation<Void, Never>?

  init(
    error: ProviderHTTPError?, waitsForCancellation: Bool,
    warmUpWaitsForResolution: Bool
  ) {
    self.error = error
    self.waitsForCancellation = waitsForCancellation
    self.warmUpWaitsForResolution = warmUpWaitsForResolution
  }

  var hasExited: Bool { lock.withLock { exited } }
  var lastConfiguration: CleanupConfiguration? { lock.withLock { recordedConfiguration } }
  var lastMode: CleanupMode? { lock.withLock { recordedMode } }
  var lastAPIKey: String? { lock.withLock { recordedAPIKey } }
  var didRequestWarmUp: Bool { lock.withLock { recordedWarmUpConfiguration != nil } }
  var lastWarmUpConfiguration: CleanupConfiguration? {
    lock.withLock { recordedWarmUpConfiguration }
  }
  var lastWarmUpAPIKey: String? { lock.withLock { recordedWarmUpAPIKey } }

  func warmUp(configuration: CleanupConfiguration, apiKey: String) async {
    if warmUpWaitsForResolution {
      await withCheckedContinuation { continuation in
        lock.withLock {
          warmUpContinuation = continuation
          recordedWarmUpConfiguration = configuration
          recordedWarmUpAPIKey = apiKey
        }
      }
    } else {
      lock.withLock {
        recordedWarmUpConfiguration = configuration
        recordedWarmUpAPIKey = apiKey
      }
    }
  }

  func resolveWarmUp() {
    let continuation = lock.withLock {
      let continuation = warmUpContinuation
      warmUpContinuation = nil
      return continuation
    }
    continuation?.resume()
  }

  func clean(
    _ text: String, mode: CleanupMode, configuration: CleanupConfiguration, apiKey: String
  ) async throws -> CleanupTextResult {
    lock.withLock {
      recordedMode = mode
      recordedConfiguration = configuration
      recordedAPIKey = apiKey
    }
    defer { lock.withLock { exited = true } }
    if waitsForCancellation { try await Task.sleep(for: .seconds(10)) }
    if let error { throw error }
    return CleanupTextResult(
      text: "Cleaned text.",
      metrics: CleanupRequestMetrics(
        actualModel: "test-model", selectedProvider: "Test Provider",
        selectedProviderModel: "test-provider-model", routingStrategy: "direct",
        routingAttempt: 1, serviceTier: "default", promptTokens: 10, completionTokens: 3,
        totalTokens: 13, httpStatus: 200))
  }
}

private final class FakeMuter: OutputMuting, @unchecked Sendable {
  private(set) var didMute = false

  func mute() -> Bool {
    didMute = true
    return true
  }
  func restore() {}
}

@MainActor
private final class FakeCuePlayer: SoundCuePlaying {
  let startCaptureDelay: Duration
  private(set) var playedCues: [DictationCue] = []

  init(startCaptureDelay: Duration) {
    self.startCaptureDelay = startCaptureDelay
  }

  func play(_ cue: DictationCue) { playedCues.append(cue) }
}

@MainActor
private final class FakeInserter: TextInserting, @unchecked Sendable {
  var insertedText: String?
  var suspendInsert = false
  var pendingInsert: CheckedContinuation<Void, Never>?
  var didReturn = false
  var onCapture: (() -> Void)?
  var captureCount = 0
  var suspendCapture = false
  var captureCancelled = false
  var result: InsertionResult = .pasteSent
  var target: TextInsertionTarget?
  var receivedTarget: TextInsertionTarget?
  func captureTarget() -> Task<TextInsertionTarget?, Never> {
    onCapture?()
    captureCount += 1
    let pinned = target
    return Task {
      if suspendCapture {
        do { try await Task.sleep(for: .seconds(10)) } catch {
          captureCancelled = true
          return nil
        }
      }
      return pinned
    }
  }
  func insert(_ text: String, into target: TextInsertionTarget?) async -> InsertionResult {
    receivedTarget = target
    if suspendInsert { await withCheckedContinuation { pendingInsert = $0 } }
    defer { didReturn = true }
    insertedText = text
    return result
  }
}

@MainActor
private final class FakeNotch: NotchPresenting {
  private(set) var presentedStates: [NotchState] = []
  private(set) var hideDelays: [Duration] = []

  func present(state: NotchState) { presentedStates.append(state) }
  func hide(after delay: Duration) { hideDelays.append(delay) }
}

@MainActor
private final class BenchmarkSpy: LatencyBenchmarkRecording {
  let directoryURL = FileManager.default.temporaryDirectory
  var isRecording = false
  var didBegin = false
  var milestones = Set<BenchmarkMilestone>()
  var orderedMilestones: [BenchmarkMilestone] = []
  var audioBytes = 0
  var audioBytesSent = 0
  var sttUpdates = 0
  var lastSTTUpdate: STTBenchmarkUpdate?
  var rawCharacters: Int?
  var cleanedCharacters: Int?
  var cleanupMetrics: CleanupRequestMetrics?
  var cleanupFallbackStatus: Int?
  var terminalResult: BenchmarkTerminalResult?
  var failureStage: BenchmarkFailureStage?
  var failureCategory: BenchmarkFailureCategory?
  var transcriptionConfiguration: TranscriptionConfiguration?

  func begin(
    enabled: Bool, transcriptionConfiguration: TranscriptionConfiguration,
    cleanupMode: CleanupMode, cleanupConfiguration: CleanupConfiguration
  ) {
    didBegin = enabled
    isRecording = enabled
    self.transcriptionConfiguration = transcriptionConfiguration
  }

  func mark(_ milestone: BenchmarkMilestone) {
    milestones.insert(milestone)
    orderedMilestones.append(milestone)
  }

  func recordAudioCaptured(bytes: Int, bufferedBytes: Int) { audioBytes += bytes }
  func recordAudioSent(bytes: Int) { audioBytesSent += bytes }
  func recordSTTUpdate(_ update: STTBenchmarkUpdate) {
    sttUpdates += 1
    lastSTTUpdate = update
  }
  func recordRawCharacters(_ count: Int) { rawCharacters = count }
  func recordCleanupMode(_ mode: CleanupMode) {}
  func recordCleanup(_ metrics: CleanupRequestMetrics) { cleanupMetrics = metrics }
  func recordCleanupFallback(rawCharacters: Int, error: Error) {
    cleanupFallbackStatus = (error as? ProviderHTTPError)?.statusCode
  }
  func recordCleanedCharacters(_ count: Int) { cleanedCharacters = count }

  func finish(
    _ result: BenchmarkTerminalResult, stage: BenchmarkFailureStage?,
    category: BenchmarkFailureCategory?, httpStatus: Int?
  ) {
    terminalResult = result
    failureStage = stage
    failureCategory = category
    isRecording = false
  }

  func clearCompletedHistory() {}
}

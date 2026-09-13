import Foundation
import XCTest

@testable import AeriVoice

@MainActor
final class DictationCoordinatorTests: XCTestCase {
  func testRestorationInvalidatesOnIdleCancelNewRecordingAndSettingOff() async throws {
    let fixture = makeFixture()
    fixture.coordinator.cancel()
    XCTAssertEqual(fixture.inserter.invalidations, 1)
    fixture.coordinator.toggle()
    XCTAssertEqual(fixture.inserter.invalidations, 2)
    fixture.preferences.restoreClipboard = false
    XCTAssertEqual(fixture.inserter.invalidations, 3)
    fixture.coordinator.cancel()
  }

  func testNoSpeechAndFinalizationFailureDiscardClipboardBackup() async throws {
    for error in [AppError.emptyTranscript, AppError.connectionTimeout] {
      let fixture = makeFixture()
      fixture.transcriber.finishError = error
      fixture.coordinator.toggle()
      try await waitUntil { fixture.coordinator.phase == .recording }
      let initial = fixture.inserter.invalidations
      fixture.coordinator.toggle()
      try await waitUntil {
        if case .error = fixture.coordinator.phase { return true }
        return false
      }
      XCTAssertEqual(fixture.inserter.invalidations, initial + 1)
      XCTAssertEqual(fixture.inserter.captureCount, 1)
      XCTAssertNil(fixture.inserter.insertedText)
      fixture.coordinator.cancel()
    }
  }

  func testTerminalFailureDiscardsClipboardBackupButPasteSentPreservesVerifier() async throws {
    for result in [InsertionResult.pasteSent, .copied(.unsupportedField), .failed("fixture")] {
      let fixture = makeFixture()
      fixture.inserter.result = result
      fixture.coordinator.toggle()
      try await waitUntil { fixture.coordinator.phase == .recording }
      let initial = fixture.inserter.invalidations
      fixture.coordinator.toggle()
      try await waitUntil { fixture.inserter.didReturn }
      XCTAssertEqual(fixture.inserter.invalidations, initial + (result == .pasteSent ? 0 : 1))
      fixture.coordinator.cancel()
    }
  }

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
    XCTAssertTrue(fixture.transcriber.didCancel)
    XCTAssertTrue(fixture.transcriber.sentFrames.isEmpty)
    XCTAssertFalse(fixture.benchmark.milestones.contains(.captureStarted))
    XCTAssertFalse(fixture.benchmark.milestones.contains(.preparedAudioEngineUsed))
    XCTAssertEqual(fixture.coordinator.phase, .error("Cancelled"))
  }

  func testProviderFailureDuringAudioStartupCancelsTheStartupTask() async throws {
    for provider in TranscriptionProvider.allCases {
      let fixture = makeFixture(
        transcriptionProvider: provider, audioStartWaitsForResolution: true)
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
      .audioEngineStartRequested, .preparedAudioEngineUsed, .captureStarted,
    ]
    XCTAssertEqual(fixture.benchmark.orderedMilestones.filter { expected.contains($0) }, expected)
    XCTAssertTrue(fixture.benchmark.milestones.contains(.sttConfigured))
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

  func testProvidersConnectDuringCueWithoutDelayingCapture() async throws {
    for provider in TranscriptionProvider.allCases {
      let fixture = makeFixture(
        transcriptionProvider: provider, soundCues: true, cueDelay: .milliseconds(20),
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

  func testSonioxCanFinishConnectingBeforeCaptureStarts() async throws {
    let fixture = makeFixture(soundCues: true, cueDelay: .milliseconds(80), connectWaitsForResolution: true)

    fixture.coordinator.toggle()
    try await waitUntil { fixture.transcriber.didConnect }

    XCTAssertFalse(fixture.audio.didStart)
    XCTAssertEqual(fixture.benchmark.audioBytes, 0)
    XCTAssertEqual(fixture.benchmark.audioBytesSent, 0)

    fixture.transcriber.resolveConnect()
    try await waitUntil { fixture.benchmark.audioBytesSent == 3_200 }
    XCTAssertEqual(fixture.benchmark.audioBytesSent, 3_200)
    fixture.coordinator.cancel()
  }

  func testCancellingWhileProviderConnectsNeverStartsCapture() async throws {
    for provider in TranscriptionProvider.allCases {
      let fixture = makeFixture(
        transcriptionProvider: provider, soundCues: true, cueDelay: .milliseconds(80),
        connectWaitsForResolution: true)
      fixture.coordinator.toggle()
      try await waitUntil { fixture.transcriber.didConnect }

      fixture.coordinator.toggle()
      try await waitUntil { fixture.benchmark.terminalResult == .cancelled }

      XCTAssertFalse(fixture.audio.didStart)
      XCTAssertFalse(fixture.muter.didMute)
      XCTAssertTrue(fixture.transcriber.didCancel)
    }
  }

  func testHeldReleaseWhileProviderConnectsNeverStartsCapture() async throws {
    for provider in TranscriptionProvider.allCases {
      let fixture = makeFixture(
        transcriptionProvider: provider, soundCues: true, cueDelay: .milliseconds(80),
        connectWaitsForResolution: true)
      let lifecycleGeneration = try XCTUnwrap(fixture.coordinator.shortcutPressed())
      try await waitUntil { fixture.transcriber.didConnect }

      fixture.coordinator.finishHeldDictation(lifecycleGeneration: lifecycleGeneration)
      try await waitUntil { fixture.benchmark.terminalResult == .cancelled }

      XCTAssertFalse(fixture.audio.didStart)
      XCTAssertFalse(fixture.muter.didMute)
      XCTAssertTrue(fixture.transcriber.didCancel)
    }
  }

  func testProviderConnectionFailureNeverStartsCapture() async throws {
    for provider in TranscriptionProvider.allCases {
      let fixture = makeFixture(
        transcriptionProvider: provider, soundCues: true, cueDelay: .milliseconds(80),
        connectError: AppError.provider("Meta connection failed"))

      fixture.coordinator.toggle()
      try await waitUntil { fixture.benchmark.terminalResult == .failed }

      XCTAssertEqual(fixture.benchmark.failureStage, .sttSetup)
      XCTAssertFalse(fixture.audio.didStart)
      XCTAssertFalse(fixture.muter.didMute)
    }
  }

  func testProviderErrorDuringCueIsClassifiedAsSetupFailure() async throws {
    for provider in TranscriptionProvider.allCases {
      let fixture = makeFixture(
        transcriptionProvider: provider, soundCues: true, cueDelay: .milliseconds(80))
      fixture.coordinator.toggle()
      try await waitUntil { fixture.cuePlayer.playedCues == [.start] }

      fixture.transcriber.emitError(AppError.provider("Meta stream failed"))
      try await waitUntil { fixture.benchmark.terminalResult == .failed }
      try await Task.sleep(for: .milliseconds(100))

      XCTAssertEqual(fixture.benchmark.failureStage, .sttSetup)
      XCTAssertFalse(fixture.audio.didStart)
      XCTAssertFalse(fixture.muter.didMute)
    }
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

  func testStoppingWhileProviderConnectsWaitsThenDrainsAllCapturedAudio() async throws {
    for provider in TranscriptionProvider.allCases {
      let fixture = makeFixture(
        transcriptionProvider: provider, connectWaitsForResolution: true, audioFrameCount: 3)
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
    XCTAssertTrue(fixture.transcriber.didCancel)
    XCTAssertTrue(fixture.transcriber.sentFrames.isEmpty)
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
    XCTAssertTrue(fixture.transcriber.didCancel)
    XCTAssertTrue(fixture.transcriber.sentFrames.isEmpty)
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
}

import Foundation
import XCTest

@testable import AeriVoice

extension DictationCoordinatorTests {
  func makeFixture(
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

  func waitUntil(
    timeout: Duration = .seconds(1), _ condition: @escaping @MainActor () -> Bool
  ) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !condition(), clock.now < deadline {
      try await Task.sleep(for: .milliseconds(5))
    }
    XCTAssertTrue(condition(), "Timed out waiting for coordinator state")
  }

  @MainActor
  struct CoordinatorFixture {
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

  final class FakeCredentialReader: CredentialReading, @unchecked Sendable {
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

  struct FakeReadiness: DictationReadinessChecking {
    func requestMicrophone() async -> Bool { true }
    func accessibilityReady(prompt: Bool) -> Bool { true }
  }

  @MainActor
  final class SuspendedReadiness: DictationReadinessChecking {
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

  final class FakeAudioCapture: AudioCapturing, @unchecked Sendable {
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
  final class FakeTranscriber: RealtimeTranscribing {
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

    var finishError: AppError?

    func finish() async throws -> String {
      if let finishError { throw finishError }
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

  final class FakeCleaner: CleaningText, @unchecked Sendable {
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

  final class FakeMuter: OutputMuting, @unchecked Sendable {
    private(set) var didMute = false

    func mute() -> Bool {
      didMute = true
      return true
    }
    func restore() {}
  }

  @MainActor
  final class FakeCuePlayer: SoundCuePlaying {
    let startCaptureDelay: Duration
    private(set) var playedCues: [DictationCue] = []

    init(startCaptureDelay: Duration) {
      self.startCaptureDelay = startCaptureDelay
    }

    func play(_ cue: DictationCue) { playedCues.append(cue) }
  }

  @MainActor
  final class FakeInserter: TextInserting, @unchecked Sendable {
    var invalidations = 0
    func invalidatePendingRestoration() { invalidations += 1 }
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
  final class FakeNotch: NotchPresenting {
    private(set) var presentedStates: [NotchState] = []
    private(set) var hideDelays: [Duration] = []

    func present(state: NotchState) { presentedStates.append(state) }
    func hide(after delay: Duration) { hideDelays.append(delay) }
  }

  @MainActor
  final class BenchmarkSpy: LatencyBenchmarkRecording {
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
}

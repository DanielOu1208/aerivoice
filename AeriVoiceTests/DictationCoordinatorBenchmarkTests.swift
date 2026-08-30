import Foundation
import XCTest

@testable import AeriVoice

@MainActor
final class DictationCoordinatorBenchmarkTests: XCTestCase {
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
    XCTAssertEqual(fixture.benchmark.terminalResult, .inserted)
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
    XCTAssertEqual(fixture.benchmark.terminalResult, .inserted)
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
      CleanupConfiguration(model: .gemini37Flash, reasoningEffort: .low))
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
    hasSonioxKey: Bool = true, cleanupError: ProviderHTTPError? = nil,
    provisionalText: String = "Raw", cleanupWaitsForCancellation: Bool = false
  ) -> CoordinatorFixture {
    let suite = "AeriVoiceTests.Coordinator.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    defaults.set(false, forKey: "soundCues")
    defaults.set(false, forKey: "muteOutput")
    let preferences = AppPreferences(defaults: defaults)
    let credentials = FakeCredentialReader(
      values: [
        .soniox: hasSonioxKey ? "soniox-key" : nil,
        .openRouter: "openrouter-key",
      ])
    let audio = FakeAudioCapture()
    let transcriber = FakeTranscriber(provisionalText: provisionalText)
    let cleaner = FakeCleaner(
      error: cleanupError, waitsForCancellation: cleanupWaitsForCancellation)
    let inserter = FakeInserter()
    let benchmark = BenchmarkSpy()
    let notch = FakeNotch()
    let coordinator = DictationCoordinator(
      preferences: preferences, credentials: credentials, audio: audio,
      transcriber: transcriber, cleaner: cleaner, muter: FakeMuter(), inserter: inserter,
      notch: notch, benchmark: benchmark, readiness: FakeReadiness())
    return CoordinatorFixture(
      preferences: preferences, coordinator: coordinator, audio: audio, transcriber: transcriber,
      inserter: inserter, cleaner: cleaner, notch: notch, benchmark: benchmark,
      defaultsSuite: suite)
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
  let notch: FakeNotch
  let benchmark: BenchmarkSpy
  let defaultsSuite: String
}

private final class FakeCredentialReader: CredentialReading, @unchecked Sendable {
  let values: [CredentialKind: String?]
  init(values: [CredentialKind: String?]) { self.values = values }
  func value(for kind: CredentialKind) -> String? { values[kind] ?? nil }
}

private struct FakeReadiness: DictationReadinessChecking {
  func requestMicrophone() async -> Bool { true }
  func accessibilityReady(prompt: Bool) -> Bool { true }
}

private final class FakeAudioCapture: AudioCapturing, @unchecked Sendable {
  var onAudio: ((Data) -> Void)?
  var didStart = false
  var didStop = false

  func start() throws {
    didStart = true
    onAudio?(Data(repeating: 0, count: 3_200))
  }

  func stop() { didStop = true }
}

@MainActor
private final class FakeTranscriber: RealtimeTranscribing {
  var onTranscript: ((RealtimeTranscriptUpdate) -> Void)?
  var onError: ((Error) -> Void)?
  var didCancel = false
  private var sentFirstUpdate = false
  private let provisionalText: String

  init(provisionalText: String) { self.provisionalText = provisionalText }

  func connect(apiKey: String, vocabulary: [String], sessionID: DictationSessionID) async throws {}

  func send(_ audio: Data) async throws {
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

  func cancel() { didCancel = true }
}

private final class FakeCleaner: CleaningText, @unchecked Sendable {
  let error: ProviderHTTPError?
  let waitsForCancellation: Bool
  private let lock = NSLock()
  private var exited = false
  private var recordedConfiguration: CleanupConfiguration?
  private var recordedMode: CleanupMode?

  init(error: ProviderHTTPError?, waitsForCancellation: Bool) {
    self.error = error
    self.waitsForCancellation = waitsForCancellation
  }

  var hasExited: Bool { lock.withLock { exited } }
  var lastConfiguration: CleanupConfiguration? { lock.withLock { recordedConfiguration } }
  var lastMode: CleanupMode? { lock.withLock { recordedMode } }

  func clean(
    _ text: String, mode: CleanupMode, configuration: CleanupConfiguration, apiKey: String
  ) async throws -> CleanupTextResult {
    lock.withLock {
      recordedMode = mode
      recordedConfiguration = configuration
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
  func mute() -> Bool { true }
  func restore() {}
}

@MainActor
private final class FakeInserter: TextInserting, @unchecked Sendable {
  var insertedText: String?
  func insert(_ text: String) async -> InsertionResult {
    insertedText = text
    return .inserted
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

  func begin(
    enabled: Bool, cleanupMode: CleanupMode, cleanupConfiguration: CleanupConfiguration
  ) {
    didBegin = enabled
    isRecording = enabled
  }

  func mark(_ milestone: BenchmarkMilestone) { milestones.insert(milestone) }

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

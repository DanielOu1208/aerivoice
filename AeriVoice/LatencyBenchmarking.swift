import Foundation
import OSLog

enum BenchmarkMilestone: String, Codable, CaseIterable, Sendable {
  case credentialReadStarted
  case credentialsReady
  case readinessCheckStarted
  case readinessChecksFinished
  case startCuePlaybackStarted
  case startCuePlaybackReturned
  case startCueDelayFinished
  case outputMuteStarted
  case outputMuteFinished
  case audioEngineStartRequested
  case preparedAudioEngineUsed
  case captureStarted
  case sttConfigured
  case firstAudioCaptured
  case firstAudioSent
  case firstSTTResponse
  case firstTranscript
  case firstFinalTranscript
  case stopRequested
  case audioCallbacksFlushed
  case audioQueueDrained
  case sttFinalizeStarted
  case sttFinalized
  case cleanupStarted
  case cleanupFinished
  case insertionStarted
  case insertionFinished
  case terminal
}

enum BenchmarkTerminalResult: String, Codable, Sendable {
  case pasteSent
  case inserted
  case insertionUnconfirmed
  case copied
  case cancelled
  case failed
  case emptyTranscript
  case interrupted
}

enum BenchmarkCleanupResult: String, Codable, Sendable {
  case applied
  case rawFallback
  case notReached
}

enum BenchmarkFailureStage: String, Codable, Sendable {
  case readiness
  case audioCapture
  case sttSetup
  case sttStream
  case sttFinalize
  case cleanup
  case insertion
  case lifecycle
}

enum BenchmarkFailureCategory: String, Codable, Sendable {
  case secureField, secureInput, readOnlyTarget, unsupportedField, targetUnavailable
  case targetChanged, modifiersHeld, shortcutUnavailable, clipboardChanged
  case missingCredential
  case microphonePermission
  case accessibilityPermission
  case connectionTimeout
  case finalizeTimeout
  case bufferOverflow
  case provider
  case network
  case cancelled
  case emptyTranscript
  case unknown
}

struct BenchmarkEnvironment: Codable, Equatable, Sendable {
  let appVersion: String?
  let appBuild: String?
  let macOSVersion: String
  let architecture: String
  var executableUUID: String? = nil
  var hardwareModel: String? = nil
  var physicalMemoryBytes: UInt64? = nil
  var logicalCPUCount: Int? = nil
  var buildConfiguration: String? = nil
  var distributionBuild: Bool? = nil
  var sourceRevision: String? = nil

  static var live: BenchmarkEnvironment {
    let info = Bundle.main.infoDictionary
    var value = BenchmarkEnvironment(
      appVersion: info?["CFBundleShortVersionString"] as? String,
      appBuild: info?["CFBundleVersion"] as? String,
      macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString,
      architecture: ProcessInfo.processInfo.machineArchitecture)
    value.executableUUID = ProcessResourceSampler.executableUUID
    value.hardwareModel = ProcessResourceSampler.hardwareModel
    value.physicalMemoryBytes = ProcessInfo.processInfo.physicalMemory
    value.logicalCPUCount = ProcessInfo.processInfo.processorCount
    #if DEBUG
      value.buildConfiguration = "Debug"
    #else
      value.buildConfiguration = "Release"
    #endif
    #if AERIVOICE_DISTRIBUTION
      value.distributionBuild = true
    #else
      value.distributionBuild = false
    #endif
    value.sourceRevision = info?["AeriVoiceSourceRevision"] as? String
    return value
  }
}

struct BenchmarkWorkload: Codable, Equatable, Sendable {
  var audioBytes = 0
  var audioBytesSent = 0
  var audioChunks = 0
  var maxBufferedAudioBytes = 0
  var transcriptUpdates = 0
  var rawCharacters: Int?
  var cleanedCharacters: Int?

  var audioDurationMS: Double {
    Double(audioBytes) / 32_000 * 1_000
  }
}

struct BenchmarkSTTMetadata: Codable, Equatable, Sendable {
  let provider: String?
  let model: String
  let audioEncoding: String?
  let zeroDataRetentionRequired: Bool?
  var finalAudioProcessedMS: Double?
  var totalAudioProcessedMS: Double?

  init(
    model: String, provider: String? = nil, audioEncoding: String? = nil,
    zeroDataRetentionRequired: Bool? = nil, finalAudioProcessedMS: Double? = nil,
    totalAudioProcessedMS: Double? = nil
  ) {
    self.provider = provider
    self.model = model
    self.audioEncoding = audioEncoding
    self.zeroDataRetentionRequired = zeroDataRetentionRequired
    self.finalAudioProcessedMS = finalAudioProcessedMS
    self.totalAudioProcessedMS = totalAudioProcessedMS
  }
}

struct BenchmarkCleanupMetadata: Codable, Equatable, Sendable {
  var mode: CleanupMode
  let requestedModel: String
  let requestedReasoningEffort: CleanupReasoningEffort?
  let requestedProviderTag: String?
  let zeroDataRetentionRequired: Bool?
  var actualModel: String?
  var selectedProvider: String?
  var selectedProviderModel: String?
  var routingStrategy: String?
  var routingAttempt: Int?
  var serviceTier: String?
  var promptTokens: Int?
  var completionTokens: Int?
  var totalTokens: Int?
  var cachedPromptTokens: Int?
  var requestEncodingMS: Double?
  var networkRequestMS: Double?
  var responseDecodingMS: Double?
  var providerTiming: CleanupProviderTimingMetrics?
  var networkTiming: CleanupNetworkTimingMetrics?
  var httpStatus: Int?
  var result: BenchmarkCleanupResult = .notReached
}

struct BenchmarkOutcome: Codable, Equatable, Sendable {
  let terminalResult: BenchmarkTerminalResult
  let failureStage: BenchmarkFailureStage?
  let failureCategory: BenchmarkFailureCategory?
  let httpStatus: Int?
}

struct STTBenchmarkUpdate: Equatable, Sendable {
  let hasTranscript: Bool
  let hasFinalText: Bool
  let finalAudioProcessedMS: Double?
  let totalAudioProcessedMS: Double?
}

struct BenchmarkDurations: Codable, Equatable, Sendable {
  var activationToCaptureMS: Double?
  var activationToStreamingMS: Double?
  var firstAudioToFirstTranscriptMS: Double?
  var firstAudioToFirstFinalMS: Double?
  var recordingMS: Double?
  var stopToCallbacksFlushedMS: Double?
  var stopToAudioDrainedMS: Double?
  var sttFinalizeMS: Double?
  var cleanupMS: Double?
  var insertionMS: Double?
  var stopToOutputMS: Double?
  var totalMS: Double?
}

struct LatencyBenchmarkRecord: Codable, Equatable, Sendable {
  let schemaVersion: Int
  let interactionID: UUID
  let startedAt: Date
  var lastCheckpointAt: Date
  var endedAt: Date?
  let environment: BenchmarkEnvironment
  var milestonesMS: [String: Double]
  var durationsMS: BenchmarkDurations
  var workload: BenchmarkWorkload
  var stt: BenchmarkSTTMetadata
  var cleanup: BenchmarkCleanupMetadata
  var outcome: BenchmarkOutcome?
  var context: InteractionDiagnosticContext? = nil
  var recordingGeneration: UUID? = nil
}

@MainActor
protocol LatencyBenchmarkRecording: AnyObject {
  var directoryURL: URL { get }
  var isRecording: Bool { get }

  func begin(
    enabled: Bool, transcriptionConfiguration: TranscriptionConfiguration,
    cleanupMode: CleanupMode, cleanupConfiguration: CleanupConfiguration)
  func mark(_ milestone: BenchmarkMilestone)
  func recordAudioCaptured(bytes: Int, bufferedBytes: Int)
  func recordAudioSent(bytes: Int)
  func recordSTTUpdate(_ update: STTBenchmarkUpdate)
  func recordRawCharacters(_ count: Int)
  func recordCleanupMode(_ mode: CleanupMode)
  func recordCleanup(_ metrics: CleanupRequestMetrics)
  func recordCleanupFallback(rawCharacters: Int, error: Error)
  func recordCleanedCharacters(_ count: Int)
  func finish(
    _ result: BenchmarkTerminalResult, stage: BenchmarkFailureStage?,
    category: BenchmarkFailureCategory?, httpStatus: Int?)
  func clearCompletedHistory()
}

@MainActor
final class LatencyBenchmarkRecorder: LatencyBenchmarkRecording {
  private struct ActiveInteraction {
    let originMS: Double
    var record: LatencyBenchmarkRecord
  }

  let directoryURL: URL
  let writer: DiagnosticsWriteQueue
  private let runtime: RuntimeDiagnosticsRecorder?
  private var collectionEnabled: Bool
  private var recordingGeneration: UUID?
  private let monotonicNowMS: () -> Double
  private let wallNow: () -> Date
  private let environment: BenchmarkEnvironment
  private var active: ActiveInteraction?

  var isRecording: Bool { active != nil }

  init(
    directoryURL: URL = LatencyBenchmarkStore.defaultDirectoryURL,
    monotonicNowMS: @escaping () -> Double = LatencyBenchmarkRecorder.liveMonotonicClock(),
    wallNow: @escaping () -> Date = Date.init,
    environment: BenchmarkEnvironment = .live,
    enabled: Bool = true,
    recordingGeneration: UUID? = nil,
    acceptLegacyCheckpoint: Bool = true,
    writer: DiagnosticsWriteQueue? = nil,
    runtime: RuntimeDiagnosticsRecorder? = nil
  ) {
    self.directoryURL = directoryURL
    self.writer = writer ?? DiagnosticsWriteQueue(directoryURL: directoryURL)
    self.runtime = runtime
    self.collectionEnabled = enabled
    self.recordingGeneration = recordingGeneration
    self.monotonicNowMS = monotonicNowMS
    self.wallNow = wallNow
    self.environment = environment
    let recoveryNow = wallNow()
    if enabled {
      self.writer.enqueue(critical: true) { store in
        try await store.recoverAndPrune(
          now: recoveryNow, allowedGeneration: recordingGeneration,
          acceptLegacyCheckpoint: acceptLegacyCheckpoint)
      }
    } else {
      self.writer.enqueue(control: true) { store in try await store.discardActiveCheckpoint() }
    }
  }

  func setEnabled(_ enabled: Bool, recordingGeneration: UUID?) {
    guard collectionEnabled != enabled else { return }
    collectionEnabled = enabled
    self.recordingGeneration = recordingGeneration
    if !enabled {
      active = nil
      writer.revokePendingCollection()
      writer.enqueue(control: true) { store in try await store.discardActiveCheckpoint() }
    }
    runtime?.setEnabled(enabled)
  }

  func begin(
    enabled: Bool,
    transcriptionConfiguration: TranscriptionConfiguration = TranscriptionConfiguration(
      provider: .soniox),
    cleanupMode: CleanupMode, cleanupConfiguration: CleanupConfiguration
  ) {
    guard active == nil else { return }
    let context = runtime?.beginInteraction()
    guard enabled, collectionEnabled else { return }
    let wallTime = wallNow()
    let route = cleanupConfiguration.model.providerRoute
    let requestedProviderTag: String? = {
      switch cleanupConfiguration.provider {
      case .groq: "groq-direct"
      case .cerebras: "cerebras-direct"
      case .openRouter: route.requestedProviderTag
      }
    }()
    var record = LatencyBenchmarkRecord(
      schemaVersion: 1,
      interactionID: context?.0 ?? UUID(),
      startedAt: wallTime,
      lastCheckpointAt: wallTime,
      environment: environment,
      milestonesMS: [:],
      durationsMS: BenchmarkDurations(),
      workload: BenchmarkWorkload(),
      stt: BenchmarkSTTMetadata(
        model: transcriptionConfiguration.modelID,
        provider: transcriptionConfiguration.provider.rawValue,
        audioEncoding: transcriptionConfiguration.audioEncoding,
        zeroDataRetentionRequired: transcriptionConfiguration.zeroDataRetentionRequired),
      cleanup: BenchmarkCleanupMetadata(
        mode: cleanupMode, requestedModel: cleanupConfiguration.model.rawValue,
        requestedReasoningEffort: cleanupConfiguration.reasoningEffort,
        requestedProviderTag: requestedProviderTag,
        zeroDataRetentionRequired: route.requiresZeroDataRetention))
    record.context = context?.1
    record.recordingGeneration = recordingGeneration
    active = ActiveInteraction(originMS: monotonicNowMS(), record: record)
    checkpoint()
  }

  func mark(_ milestone: BenchmarkMilestone) {
    runtime?.milestone(milestone)
    guard var active, active.record.milestonesMS[milestone.rawValue] == nil else { return }
    let elapsed = elapsedMS(for: active)
    active.record.milestonesMS[milestone.rawValue] = elapsed
    active.record.lastCheckpointAt = wallNow()
    self.active = active
    checkpoint()
  }

  func recordAudioCaptured(bytes: Int, bufferedBytes: Int) {
    guard var active else { return }
    active.record.workload.audioBytes += bytes
    active.record.workload.audioChunks += 1
    active.record.workload.maxBufferedAudioBytes = max(
      active.record.workload.maxBufferedAudioBytes, bufferedBytes)
    if active.record.milestonesMS[BenchmarkMilestone.firstAudioCaptured.rawValue] == nil {
      active.record.milestonesMS[BenchmarkMilestone.firstAudioCaptured.rawValue] = elapsedMS(
        for: active)
      active.record.lastCheckpointAt = wallNow()
      self.active = active
      checkpoint()
    } else {
      self.active = active
    }
  }

  func recordAudioSent(bytes: Int) {
    guard var active else { return }
    active.record.workload.audioBytesSent += bytes
    if active.record.milestonesMS[BenchmarkMilestone.firstAudioSent.rawValue] == nil {
      active.record.milestonesMS[BenchmarkMilestone.firstAudioSent.rawValue] = elapsedMS(
        for: active)
      active.record.lastCheckpointAt = wallNow()
      self.active = active
      checkpoint()
    } else {
      self.active = active
    }
  }

  func recordSTTUpdate(_ update: STTBenchmarkUpdate) {
    guard var active else { return }
    active.record.workload.transcriptUpdates += 1
    if let value = update.finalAudioProcessedMS {
      active.record.stt.finalAudioProcessedMS = value
    }
    if let value = update.totalAudioProcessedMS {
      active.record.stt.totalAudioProcessedMS = value
    }
    let elapsed = elapsedMS(for: active)
    var needsCheckpoint = setIfMissing(.firstSTTResponse, elapsed: elapsed, active: &active)
    if update.hasTranscript {
      needsCheckpoint =
        setIfMissing(.firstTranscript, elapsed: elapsed, active: &active)
        || needsCheckpoint
    }
    if update.hasFinalText {
      needsCheckpoint =
        setIfMissing(.firstFinalTranscript, elapsed: elapsed, active: &active)
        || needsCheckpoint
    }
    if needsCheckpoint { active.record.lastCheckpointAt = wallNow() }
    self.active = active
    if needsCheckpoint { checkpoint() }
  }

  func recordRawCharacters(_ count: Int) {
    active?.record.workload.rawCharacters = count
  }

  func recordCleanupMode(_ mode: CleanupMode) {
    active?.record.cleanup.mode = mode
  }

  func recordCleanup(_ metrics: CleanupRequestMetrics) {
    guard var active else { return }
    Self.apply(metrics, to: &active.record.cleanup)
    active.record.cleanup.result = .applied
    self.active = active
  }

  func recordCleanupFallback(rawCharacters: Int, error: Error) {
    guard var active else { return }
    active.record.workload.cleanedCharacters = rawCharacters
    active.record.cleanup.result = .rawFallback
    if let error = error as? ProviderHTTPError {
      if let metrics = error.cleanupMetrics {
        Self.apply(metrics, to: &active.record.cleanup)
      } else {
        active.record.cleanup.httpStatus = error.statusCode
      }
    } else if let error = error as? CleanupNetworkError {
      Self.apply(error.cleanupMetrics, to: &active.record.cleanup)
    }
    self.active = active
  }

  func recordCleanedCharacters(_ count: Int) {
    active?.record.workload.cleanedCharacters = count
  }

  func finish(
    _ result: BenchmarkTerminalResult, stage: BenchmarkFailureStage? = nil,
    category: BenchmarkFailureCategory? = nil, httpStatus: Int? = nil
  ) {
    runtime?.finishInteraction()
    guard var active else { return }
    let elapsed = elapsedMS(for: active)
    active.record.milestonesMS[BenchmarkMilestone.terminal.rawValue] = elapsed
    active.record.lastCheckpointAt = wallNow()
    active.record.endedAt = active.record.lastCheckpointAt
    active.record.outcome = BenchmarkOutcome(
      terminalResult: result, failureStage: stage, failureCategory: category,
      httpStatus: httpStatus)
    active.record.durationsMS = Self.makeDurations(from: active.record.milestonesMS)
    self.active = nil
    let finalRecord = active.record
    writer.enqueue(critical: true) { store in try await store.complete(finalRecord, now: finalRecord.endedAt!) }
  }

  func clearCompletedHistory() {
    runtime?.historyWillClear()
    writer.enqueue(control: true) { store in try await store.clearCompletedHistory() }
  }

  func flushForTesting() async {
    await writer.flush()
  }

  @discardableResult
  func flushBeforeTermination(timeout: TimeInterval = 2) -> Bool {
    writer.flushBeforeTermination(timeout: timeout)
  }

  private func checkpoint() {
    guard let record = active?.record else { return }
    enqueue { store in try await store.checkpoint(record) }
  }

  private func elapsedMS(for active: ActiveInteraction) -> Double {
    max(0, monotonicNowMS() - active.originMS)
  }

  private func setIfMissing(
    _ milestone: BenchmarkMilestone, elapsed: Double, active: inout ActiveInteraction
  ) -> Bool {
    guard active.record.milestonesMS[milestone.rawValue] == nil else { return false }
    active.record.milestonesMS[milestone.rawValue] = elapsed
    return true
  }

  nonisolated private static func apply(
    _ metrics: CleanupRequestMetrics, to cleanup: inout BenchmarkCleanupMetadata
  ) {
    cleanup.actualModel = metrics.actualModel
    cleanup.selectedProvider = metrics.selectedProvider
    cleanup.selectedProviderModel = metrics.selectedProviderModel
    cleanup.routingStrategy = metrics.routingStrategy
    cleanup.routingAttempt = metrics.routingAttempt
    cleanup.serviceTier = metrics.serviceTier
    cleanup.promptTokens = metrics.promptTokens
    cleanup.completionTokens = metrics.completionTokens
    cleanup.totalTokens = metrics.totalTokens
    cleanup.cachedPromptTokens = metrics.cachedPromptTokens
    cleanup.requestEncodingMS = metrics.requestEncodingMS
    cleanup.networkRequestMS = metrics.networkRequestMS
    cleanup.responseDecodingMS = metrics.responseDecodingMS
    cleanup.providerTiming = metrics.providerTiming
    cleanup.networkTiming = metrics.networkTiming
    cleanup.httpStatus = metrics.httpStatus
  }

  private func enqueue(
    _ operation: @escaping @Sendable (LatencyBenchmarkStore) async throws -> Void
  ) {
    writer.enqueue(operation)
  }

  nonisolated private static func makeDurations(from values: [String: Double])
    -> BenchmarkDurations
  {
    func value(_ milestone: BenchmarkMilestone) -> Double? { values[milestone.rawValue] }
    func difference(_ start: BenchmarkMilestone, _ end: BenchmarkMilestone) -> Double? {
      guard let start = value(start), let end = value(end) else { return nil }
      return max(0, end - start)
    }
    return BenchmarkDurations(
      activationToCaptureMS: value(.captureStarted),
      activationToStreamingMS: value(.sttConfigured),
      firstAudioToFirstTranscriptMS: difference(.firstAudioCaptured, .firstTranscript),
      firstAudioToFirstFinalMS: difference(.firstAudioCaptured, .firstFinalTranscript),
      recordingMS: difference(.captureStarted, .stopRequested),
      stopToCallbacksFlushedMS: difference(.stopRequested, .audioCallbacksFlushed),
      stopToAudioDrainedMS: difference(.stopRequested, .audioQueueDrained),
      sttFinalizeMS: difference(.sttFinalizeStarted, .sttFinalized),
      cleanupMS: difference(.cleanupStarted, .cleanupFinished),
      insertionMS: difference(.insertionStarted, .insertionFinished),
      stopToOutputMS: difference(.stopRequested, .insertionFinished),
      totalMS: value(.terminal))
  }

  private static func liveMonotonicClock() -> () -> Double {
    let clock = ContinuousClock()
    let origin = clock.now
    return {
      let duration = origin.duration(to: clock.now)
      let components = duration.components
      return Double(components.seconds) * 1_000
        + Double(components.attoseconds) / 1_000_000_000_000_000
    }
  }
}

extension LatencyBenchmarkRecorder {
  nonisolated static func makeDurationsForStore(from values: [String: Double])
    -> BenchmarkDurations
  {
    makeDurations(from: values)
  }
}

extension ProcessInfo {
  fileprivate var machineArchitecture: String {
    #if arch(arm64)
      return "arm64"
    #elseif arch(x86_64)
      return "x86_64"
    #else
      return "unknown"
    #endif
  }
}

import Foundation
import OSLog

enum BenchmarkMilestone: String, Codable, CaseIterable, Sendable {
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
  case inserted
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

  static var live: BenchmarkEnvironment {
    let info = Bundle.main.infoDictionary
    return BenchmarkEnvironment(
      appVersion: info?["CFBundleShortVersionString"] as? String,
      appBuild: info?["CFBundleVersion"] as? String,
      macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString,
      architecture: ProcessInfo.processInfo.machineArchitecture)
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
  let model: String
  var finalAudioProcessedMS: Double?
  var totalAudioProcessedMS: Double?
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
}

@MainActor
protocol LatencyBenchmarkRecording: AnyObject {
  var directoryURL: URL { get }
  var isRecording: Bool { get }

  func begin(
    enabled: Bool, cleanupMode: CleanupMode, cleanupConfiguration: CleanupConfiguration)
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
  private let store: LatencyBenchmarkStore
  private let monotonicNowMS: () -> Double
  private let wallNow: () -> Date
  private let environment: BenchmarkEnvironment
  private var active: ActiveInteraction?
  private var persistenceTask: Task<Void, Never>?
  private let logger = Logger(subsystem: "com.danielou.AeriVoice", category: "LatencyBenchmark")

  var isRecording: Bool { active != nil }

  init(
    directoryURL: URL = LatencyBenchmarkStore.defaultDirectoryURL,
    monotonicNowMS: @escaping () -> Double = LatencyBenchmarkRecorder.liveMonotonicClock(),
    wallNow: @escaping () -> Date = Date.init,
    environment: BenchmarkEnvironment = .live
  ) {
    self.directoryURL = directoryURL
    store = LatencyBenchmarkStore(directoryURL: directoryURL)
    self.monotonicNowMS = monotonicNowMS
    self.wallNow = wallNow
    self.environment = environment
    let recoveryNow = wallNow()
    enqueue { store in try await store.recoverAndPrune(now: recoveryNow) }
  }

  func begin(
    enabled: Bool, cleanupMode: CleanupMode, cleanupConfiguration: CleanupConfiguration
  ) {
    guard enabled, active == nil else { return }
    let wallTime = wallNow()
    let route = cleanupConfiguration.model.providerRoute
    let record = LatencyBenchmarkRecord(
      schemaVersion: 1,
      interactionID: UUID(),
      startedAt: wallTime,
      lastCheckpointAt: wallTime,
      environment: environment,
      milestonesMS: [:],
      durationsMS: BenchmarkDurations(),
      workload: BenchmarkWorkload(),
      stt: BenchmarkSTTMetadata(model: "stt-rt-v5"),
      cleanup: BenchmarkCleanupMetadata(
        mode: cleanupMode, requestedModel: cleanupConfiguration.model.rawValue,
        requestedReasoningEffort: cleanupConfiguration.reasoningEffort,
        requestedProviderTag: route.requestedProviderTag,
        zeroDataRetentionRequired: route.requiresZeroDataRetention))
    active = ActiveInteraction(originMS: monotonicNowMS(), record: record)
    checkpoint()
  }

  func mark(_ milestone: BenchmarkMilestone) {
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
    enqueue { store in try await store.complete(finalRecord, now: finalRecord.endedAt!) }
  }

  func clearCompletedHistory() {
    enqueue { store in try await store.clearCompletedHistory() }
  }

  func flushForTesting() async {
    await persistenceTask?.value
  }

  @discardableResult
  func flushBeforeTermination(timeout: TimeInterval = 2) -> Bool {
    guard let persistenceTask else { return true }
    let semaphore = DispatchSemaphore(value: 0)
    Task.detached {
      await persistenceTask.value
      semaphore.signal()
    }
    return semaphore.wait(timeout: .now() + timeout) == .success
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
    cleanup.httpStatus = metrics.httpStatus
  }

  private func enqueue(
    _ operation: @escaping @Sendable (LatencyBenchmarkStore) async throws -> Void
  ) {
    let previous = persistenceTask
    let store = self.store
    let logger = self.logger
    persistenceTask = Task.detached(priority: .utility) {
      await previous?.value
      do {
        try await operation(store)
      } catch {
        logger.error("Latency benchmark persistence failed")
      }
    }
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

actor LatencyBenchmarkStore {
  static let logFilename = "interactions-v1.jsonl"
  static let activeFilename = "active-interaction-v1.json"
  static let retentionDays = 90

  static var defaultDirectoryURL: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appending(path: "AeriVoice/Benchmarks", directoryHint: .isDirectory)
  }

  let directoryURL: URL
  private let fileManager: FileManager
  private let encoder: JSONEncoder
  private let decoder: JSONDecoder
  private var lastPrunedAt: Date?

  init(directoryURL: URL, fileManager: FileManager = .default) {
    self.directoryURL = directoryURL
    self.fileManager = fileManager
    encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
  }

  func checkpoint(_ record: LatencyBenchmarkRecord) throws {
    try prepareDirectory()
    let url = directoryURL.appending(path: Self.activeFilename)
    try encoder.encode(record).write(to: url, options: .atomic)
    try setPermissions(0o600, at: url)
  }

  func complete(_ record: LatencyBenchmarkRecord, now: Date) throws {
    try prepareDirectory()
    try append(record)
    let activeURL = directoryURL.appending(path: Self.activeFilename)
    if let activeData = try? Data(contentsOf: activeURL),
      let activeRecord = try? decoder.decode(LatencyBenchmarkRecord.self, from: activeData),
      activeRecord.interactionID == record.interactionID
    {
      try fileManager.removeItem(at: activeURL)
    }
    try pruneIfNeeded(now: now)
  }

  func recoverAndPrune(now: Date) throws {
    try prepareDirectory()
    let activeURL = directoryURL.appending(path: Self.activeFilename)
    if let data = try? Data(contentsOf: activeURL),
      var record = try? decoder.decode(LatencyBenchmarkRecord.self, from: data)
    {
      if try containsCompletedRecord(interactionID: record.interactionID) {
        try fileManager.removeItem(at: activeURL)
        try prune(now: now)
        return
      }
      let lastElapsed = record.milestonesMS.values.max() ?? 0
      record.milestonesMS[BenchmarkMilestone.terminal.rawValue] = lastElapsed
      record.endedAt = record.lastCheckpointAt
      record.outcome = BenchmarkOutcome(
        terminalResult: .interrupted, failureStage: .lifecycle,
        failureCategory: .unknown, httpStatus: nil)
      record.durationsMS = LatencyBenchmarkRecorder.makeDurationsForStore(
        from: record.milestonesMS)
      try append(record)
      try fileManager.removeItem(at: activeURL)
    }
    try prune(now: now)
  }

  func clearCompletedHistory() throws {
    let url = directoryURL.appending(path: Self.logFilename)
    if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
  }

  private func append(_ record: LatencyBenchmarkRecord) throws {
    let url = directoryURL.appending(path: Self.logFilename)
    var line = try encoder.encode(record)
    line.append(0x0A)
    if !fileManager.fileExists(atPath: url.path) {
      guard
        fileManager.createFile(
          atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
      else { throw CocoaError(.fileWriteUnknown) }
    }
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: line)
    try setPermissions(0o600, at: url)
  }

  private func containsCompletedRecord(interactionID: UUID) throws -> Bool {
    let url = directoryURL.appending(path: Self.logFilename)
    guard let data = try? Data(contentsOf: url) else { return false }
    return data.split(separator: 0x0A).contains { line in
      (try? decoder.decode(LatencyBenchmarkRecord.self, from: Data(line)).interactionID)
        == interactionID
    }
  }

  private func pruneIfNeeded(now: Date) throws {
    guard lastPrunedAt.map({ now.timeIntervalSince($0) >= 86_400 }) ?? true else { return }
    try prune(now: now)
  }

  private func prune(now: Date) throws {
    lastPrunedAt = now
    let url = directoryURL.appending(path: Self.logFilename)
    guard let data = try? Data(contentsOf: url), !data.isEmpty else { return }
    let cutoff = now.addingTimeInterval(-Double(Self.retentionDays) * 86_400)
    var retained = Data()
    for line in data.split(separator: 0x0A) where !line.isEmpty {
      let lineData = Data(line)
      if let record = try? decoder.decode(LatencyBenchmarkRecord.self, from: lineData),
        record.schemaVersion == 1, record.startedAt < cutoff
      {
        continue
      }
      retained.append(lineData)
      retained.append(0x0A)
    }
    try retained.write(to: url, options: .atomic)
    try setPermissions(0o600, at: url)
  }

  private func prepareDirectory() throws {
    try fileManager.createDirectory(
      at: directoryURL, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    try setPermissions(0o700, at: directoryURL)
  }

  private func setPermissions(_ permissions: Int, at url: URL) throws {
    try fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
  }
}

extension LatencyBenchmarkRecorder {
  nonisolated fileprivate static func makeDurationsForStore(from values: [String: Double])
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

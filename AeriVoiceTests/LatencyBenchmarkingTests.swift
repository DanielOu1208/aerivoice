import Foundation
import XCTest

@testable import AeriVoice

@MainActor
final class LatencyBenchmarkingTests: XCTestCase {
  func testRecorderWritesDeterministicPrivacySafeInteraction() async throws {
    let directory = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let clock = TestClock(milliseconds: 1_000)
    let wallClock = TestWallClock(date: Date(timeIntervalSince1970: 2_000_000_000))
    let recorder = makeRecorder(directory: directory, clock: clock, wallClock: wallClock)
    await recorder.flushForTesting()

    recorder.begin(
      enabled: true, cleanupMode: .faithful,
      cleanupConfiguration: CleanupConfiguration(
        model: .gptOSS120BCerebras, reasoningEffort: .high))
    clock.milliseconds = 1_010
    recorder.mark(.captureStarted)
    clock.milliseconds = 1_015
    recorder.recordAudioCaptured(bytes: 3_200, bufferedBytes: 3_200)
    clock.milliseconds = 1_020
    recorder.mark(.sttConfigured)
    clock.milliseconds = 1_025
    recorder.recordAudioSent(bytes: 3_200)
    clock.milliseconds = 1_100
    recorder.recordSTTUpdate(
      STTBenchmarkUpdate(
        hasTranscript: true, hasFinalText: false, finalAudioProcessedMS: 0,
        totalAudioProcessedMS: 80))
    clock.milliseconds = 1_200
    recorder.recordSTTUpdate(
      STTBenchmarkUpdate(
        hasTranscript: true, hasFinalText: true, finalAudioProcessedMS: 100,
        totalAudioProcessedMS: 100))
    clock.milliseconds = 1_300
    recorder.mark(.stopRequested)
    clock.milliseconds = 1_310
    recorder.mark(.audioCallbacksFlushed)
    clock.milliseconds = 1_320
    recorder.mark(.audioQueueDrained)
    clock.milliseconds = 1_325
    recorder.mark(.sttFinalizeStarted)
    clock.milliseconds = 1_335
    recorder.mark(.sttFinalized)
    recorder.recordRawCharacters(17)
    clock.milliseconds = 1_340
    recorder.mark(.cleanupStarted)
    recorder.recordCleanup(
      CleanupRequestMetrics(
        actualModel: "actual-model", selectedProvider: "provider",
        selectedProviderModel: "provider-model", routingStrategy: "direct",
        routingAttempt: 1, serviceTier: "default", promptTokens: 20,
        completionTokens: 4, totalTokens: 24, httpStatus: 200))
    recorder.recordCleanedCharacters(19)
    clock.milliseconds = 1_390
    recorder.mark(.cleanupFinished)
    clock.milliseconds = 1_395
    recorder.mark(.insertionStarted)
    clock.milliseconds = 1_400
    recorder.mark(.insertionFinished)
    clock.milliseconds = 1_405
    wallClock.date = wallClock.date.addingTimeInterval(0.405)
    recorder.finish(.inserted, stage: nil, category: nil, httpStatus: nil)
    clock.milliseconds = 2_000
    recorder.begin(
      enabled: true, cleanupMode: .polished,
      cleanupConfiguration: defaultCleanupConfiguration)
    recorder.recordCleanupFallback(
      rawCharacters: 14,
      error: ProviderHTTPError(statusCode: 503, message: "SECRET_PROVIDER_ERROR"))
    clock.milliseconds = 2_010
    recorder.finish(.failed, stage: .cleanup, category: .provider, httpStatus: 503)
    await recorder.flushForTesting()

    let logURL = directory.appending(path: LatencyBenchmarkStore.logFilename)
    let data = try Data(contentsOf: logURL)
    let serialized = String(decoding: data, as: UTF8.self)
    XCTAssertFalse(serialized.contains("SECRET_PROVIDER_ERROR"))

    let record = try XCTUnwrap(try decodeRecords(at: logURL).first)
    XCTAssertEqual(record.workload.audioBytes, 3_200)
    XCTAssertEqual(record.workload.audioDurationMS, 100, accuracy: 0.001)
    XCTAssertEqual(record.workload.transcriptUpdates, 2)
    XCTAssertEqual(record.stt.finalAudioProcessedMS, 100)
    XCTAssertEqual(record.cleanup.selectedProvider, "provider")
    XCTAssertEqual(record.cleanup.requestedModel, "openai/gpt-oss-120b")
    XCTAssertEqual(record.cleanup.requestedReasoningEffort, .high)
    XCTAssertEqual(record.cleanup.requestedProviderTag, "cerebras/fp16")
    XCTAssertEqual(record.cleanup.zeroDataRetentionRequired, true)
    XCTAssertEqual(record.cleanup.result, .applied)
    XCTAssertEqual(record.outcome?.terminalResult, .inserted)
    XCTAssertEqual(record.durationsMS.activationToCaptureMS, 10)
    XCTAssertEqual(record.durationsMS.firstAudioToFirstTranscriptMS, 85)
    XCTAssertEqual(record.durationsMS.firstAudioToFirstFinalMS, 185)
    XCTAssertEqual(record.durationsMS.recordingMS, 290)
    XCTAssertEqual(record.durationsMS.stopToCallbacksFlushedMS, 10)
    XCTAssertEqual(record.durationsMS.stopToAudioDrainedMS, 20)
    XCTAssertEqual(record.durationsMS.sttFinalizeMS, 10)
    XCTAssertEqual(record.durationsMS.cleanupMS, 50)
    XCTAssertEqual(record.durationsMS.insertionMS, 5)
    XCTAssertEqual(record.durationsMS.stopToOutputMS, 100)
    XCTAssertEqual(record.durationsMS.totalMS, 405)

    let fileAttributes = try FileManager.default.attributesOfItem(atPath: logURL.path)
    XCTAssertEqual((fileAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    let directoryAttributes = try FileManager.default.attributesOfItem(atPath: directory.path)
    XCTAssertEqual((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
  }

  func testDisabledLoggingCreatesNoInteractionFile() async {
    let directory = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let recorder = makeRecorder(
      directory: directory, clock: TestClock(milliseconds: 0),
      wallClock: TestWallClock(date: Date()))
    await recorder.flushForTesting()

    recorder.begin(
      enabled: false, cleanupMode: .polished,
      cleanupConfiguration: defaultCleanupConfiguration)
    recorder.mark(.captureStarted)
    recorder.finish(.inserted, stage: nil, category: nil, httpStatus: nil)
    await recorder.flushForTesting()

    XCTAssertFalse(recorder.isRecording)
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: directory.appending(path: LatencyBenchmarkStore.logFilename).path))
  }

  func testLegacyRecordWithoutRoutingMetadataStillDecodes() throws {
    let legacyJSON = #"""
      {
        "schemaVersion": 1,
        "interactionID": "00000000-0000-0000-0000-000000000001",
        "startedAt": "2033-05-18T03:33:20Z",
        "lastCheckpointAt": "2033-05-18T03:33:20Z",
        "environment": {
          "macOSVersion": "TestOS",
          "architecture": "arm64"
        },
        "milestonesMS": {},
        "durationsMS": {},
        "workload": {
          "audioBytes": 0,
          "audioBytesSent": 0,
          "audioChunks": 0,
          "maxBufferedAudioBytes": 0,
          "transcriptUpdates": 0
        },
        "stt": { "model": "stt-rt-v5" },
        "cleanup": {
          "mode": "Faithful",
          "requestedModel": "google/gemini-3.7-flash",
          "result": "notReached"
        }
      }
      """#
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    let record = try decoder.decode(LatencyBenchmarkRecord.self, from: Data(legacyJSON.utf8))

    XCTAssertEqual(record.cleanup.requestedModel, "google/gemini-3.7-flash")
    XCTAssertNil(record.cleanup.requestedReasoningEffort)
    XCTAssertNil(record.cleanup.requestedProviderTag)
    XCTAssertNil(record.cleanup.zeroDataRetentionRequired)
  }

  func testActiveCheckpointRecoversAsInterruptedOnNextLaunch() async throws {
    let directory = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let clock = TestClock(milliseconds: 0)
    let wallClock = TestWallClock(date: Date(timeIntervalSince1970: 2_000_000_000))
    let firstRecorder = makeRecorder(directory: directory, clock: clock, wallClock: wallClock)
    await firstRecorder.flushForTesting()
    firstRecorder.begin(
      enabled: true, cleanupMode: .faithful,
      cleanupConfiguration: defaultCleanupConfiguration)
    clock.milliseconds = 25
    recorderMarkCapture(firstRecorder)
    await firstRecorder.flushForTesting()

    let recoveredRecorder = makeRecorder(directory: directory, clock: clock, wallClock: wallClock)
    await recoveredRecorder.flushForTesting()

    let logURL = directory.appending(path: LatencyBenchmarkStore.logFilename)
    let record = try XCTUnwrap(try decodeRecords(at: logURL).first)
    XCTAssertEqual(record.outcome?.terminalResult, .interrupted)
    XCTAssertEqual(record.outcome?.failureStage, .lifecycle)
    XCTAssertEqual(record.durationsMS.totalMS, 25)
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: directory.appending(path: LatencyBenchmarkStore.activeFilename).path))
  }

  func testRecoveryDoesNotDuplicateCompletedInteractionWithStaleSidecar() async throws {
    let directory = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = LatencyBenchmarkStore(directoryURL: directory)
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let record = makeStoredRecord(startedAt: now)

    try await store.complete(record, now: now)
    try await store.checkpoint(record)
    try await store.recoverAndPrune(now: now)

    let records = try decodeRecords(
      at: directory.appending(path: LatencyBenchmarkStore.logFilename))
    XCTAssertEqual(records.map(\.interactionID), [record.interactionID])
    XCTAssertEqual(records.first?.outcome?.terminalResult, .inserted)
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: directory.appending(path: LatencyBenchmarkStore.activeFilename).path))
  }

  func testTerminationFlushMakesFinalOutcomeDurable() throws {
    let directory = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let clock = TestClock(milliseconds: 0)
    let wallClock = TestWallClock(date: Date(timeIntervalSince1970: 2_000_000_000))
    let recorder = makeRecorder(directory: directory, clock: clock, wallClock: wallClock)

    recorder.begin(
      enabled: true, cleanupMode: .faithful,
      cleanupConfiguration: defaultCleanupConfiguration)
    clock.milliseconds = 10
    recorder.finish(.cancelled, stage: .lifecycle, category: .cancelled, httpStatus: nil)

    XCTAssertTrue(recorder.flushBeforeTermination(timeout: 1))
    let records = try decodeRecords(
      at: directory.appending(path: LatencyBenchmarkStore.logFilename))
    XCTAssertEqual(records.count, 1)
    XCTAssertEqual(records.first?.outcome?.terminalResult, .cancelled)
  }

  func testRetentionPrunesOldRecordsAndPreservesMalformedLines() async throws {
    let directory = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = LatencyBenchmarkStore(directoryURL: directory)
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let oldDate = now.addingTimeInterval(-91 * 86_400)
    let recentDate = now.addingTimeInterval(-5 * 86_400)

    try await store.complete(makeStoredRecord(startedAt: oldDate), now: oldDate)
    try await store.complete(
      makeStoredRecord(startedAt: oldDate, schemaVersion: 2),
      now: oldDate.addingTimeInterval(0.5))
    try await store.complete(
      makeStoredRecord(startedAt: recentDate), now: oldDate.addingTimeInterval(1))
    let logURL = directory.appending(path: LatencyBenchmarkStore.logFilename)
    let handle = try FileHandle(forWritingTo: logURL)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("{malformed-but-preserved}\n".utf8))
    try handle.close()

    try await store.recoverAndPrune(now: now)

    let contents = String(decoding: try Data(contentsOf: logURL), as: UTF8.self)
    XCTAssertTrue(contents.contains("malformed-but-preserved"))
    let records = try decodeRecords(at: logURL, ignoringMalformed: true)
    XCTAssertEqual(records.count, 2)
    XCTAssertTrue(records.contains { $0.schemaVersion == 2 && $0.startedAt == oldDate })
    XCTAssertTrue(records.contains { $0.schemaVersion == 1 && $0.startedAt == recentDate })
  }

  private func makeRecorder(
    directory: URL, clock: TestClock, wallClock: TestWallClock
  ) -> LatencyBenchmarkRecorder {
    LatencyBenchmarkRecorder(
      directoryURL: directory, monotonicNowMS: { clock.milliseconds },
      wallNow: { wallClock.date },
      environment: BenchmarkEnvironment(
        appVersion: "1.0", appBuild: "1", macOSVersion: "TestOS",
        architecture: "arm64"))
  }

  private func recorderMarkCapture(_ recorder: LatencyBenchmarkRecorder) {
    recorder.mark(.captureStarted)
  }

  private func makeTemporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory
      .appending(path: "AeriVoiceBenchmarkTests-\(UUID().uuidString)", directoryHint: .isDirectory)
  }

  private func decodeRecords(at url: URL, ignoringMalformed: Bool = false) throws
    -> [LatencyBenchmarkRecord]
  {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try Data(contentsOf: url).split(separator: 0x0A).compactMap { line in
      do { return try decoder.decode(LatencyBenchmarkRecord.self, from: Data(line)) } catch {
        if ignoringMalformed { return nil }
        throw error
      }
    }
  }

  private func makeStoredRecord(startedAt: Date, schemaVersion: Int = 1)
    -> LatencyBenchmarkRecord
  {
    LatencyBenchmarkRecord(
      schemaVersion: schemaVersion, interactionID: UUID(), startedAt: startedAt,
      lastCheckpointAt: startedAt, endedAt: startedAt,
      environment: BenchmarkEnvironment(
        appVersion: nil, appBuild: nil, macOSVersion: "TestOS", architecture: "arm64"),
      milestonesMS: [BenchmarkMilestone.terminal.rawValue: 1],
      durationsMS: BenchmarkDurations(totalMS: 1), workload: BenchmarkWorkload(),
      stt: BenchmarkSTTMetadata(model: "stt-rt-v5"),
      cleanup: BenchmarkCleanupMetadata(
        mode: .faithful, requestedModel: CleanupModel.defaultModel.rawValue,
        requestedReasoningEffort: nil, requestedProviderTag: nil,
        zeroDataRetentionRequired: nil),
      outcome: BenchmarkOutcome(
        terminalResult: .inserted, failureStage: nil, failureCategory: nil, httpStatus: nil))
  }

  private var defaultCleanupConfiguration: CleanupConfiguration {
    CleanupConfiguration(model: .defaultModel, reasoningEffort: .low)
  }
}

private final class TestClock {
  var milliseconds: Double
  init(milliseconds: Double) { self.milliseconds = milliseconds }
}

private final class TestWallClock {
  var date: Date
  init(date: Date) { self.date = date }
}

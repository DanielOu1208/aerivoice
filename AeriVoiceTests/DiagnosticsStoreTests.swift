import Darwin
import Foundation
import XCTest

@testable import AeriVoice

final class DiagnosticsStoreTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 2_000_000_000)

  func testRuntimeRotatesBySizeAndDay() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = LatencyBenchmarkStore(directoryURL: directory, rotationBytes: 160)
    try await store.appendRuntime(runtime(now), now: now)
    try await store.appendRuntime(runtime(now), now: now)
    XCTAssertEqual(try archives(directory).count, 1)
    try await store.appendRuntime(runtime(now.addingTimeInterval(86_400)), now: now.addingTimeInterval(86_400))
    XCTAssertEqual(try archives(directory).count, 2)
  }

  func testMixedAgeArchiveExpiresOldRecordsAndKeepsYoungerRecords() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = LatencyBenchmarkStore(directoryURL: directory, rotationBytes: 1)
    try await store.recoverAndPrune(now: now)
    let oldDate = now.addingTimeInterval(-364 * 86_400)
    let current = directory.appending(path: LatencyBenchmarkStore.runtimeFilename)
    var legacy = runtime(oldDate)
    legacy.append(0x0A)
    legacy.append(runtime(now))
    legacy.append(0x0A)
    try legacy.write(to: current)
    try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: current.path)
    // Rotate the mixed legacy file while neither of its records has expired.
    try await store.appendRuntime(runtime(now), now: now)
    let archive = try XCTUnwrap(archives(directory).first)
    let archiveIdentity = try FileManager.default.attributesOfItem(atPath: archive.path)[.systemFileNumber] as? NSNumber
    try await store.appendRuntime(runtime(now), now: now.addingTimeInterval(86_400))
    XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: archive.path)[.systemFileNumber] as? NSNumber,
                   archiveIdentity, "An unchanged archive must not be rewritten")
    try await store.appendRuntime(runtime(now), now: now.addingTimeInterval(2 * 86_400))
    XCTAssertEqual(try Data(contentsOf: archive), runtime(now) + Data([0x0A]))
  }

  func testRecoveryDeduplicatesAcrossArchives() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = LatencyBenchmarkStore(directoryURL: directory, rotationBytes: 1)
    let record = storedRecord()
    try await store.complete(record, now: now)
    try await store.complete(storedRecord(), now: now)
    try await store.checkpoint(record)
    try await store.recoverAndPrune(now: now)
    let logs = try archives(directory) + [directory.appending(path: LatencyBenchmarkStore.logFilename)]
    let occurrences = try logs.reduce(0) { count, url in
      count + String(decoding: try Data(contentsOf: url), as: UTF8.self)
        .components(separatedBy: record.interactionID.uuidString).count - 1
    }
    XCTAssertEqual(occurrences, 1)
    XCTAssertFalse(exists(directory, LatencyBenchmarkStore.activeFilename))
  }

  func testRevokedGenerationAndDisabledLegacyAreDiscarded() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = LatencyBenchmarkStore(directoryURL: directory)
    var record = storedRecord()
    record.recordingGeneration = UUID()
    try await store.checkpoint(record)
    try await store.recoverAndPrune(now: now, allowedGeneration: UUID(), acceptLegacyCheckpoint: false)
    XCTAssertFalse(exists(directory, LatencyBenchmarkStore.logFilename))
    XCTAssertFalse(exists(directory, LatencyBenchmarkStore.activeFilename))
    record.recordingGeneration = nil
    try await store.checkpoint(record)
    try await store.recoverAndPrune(now: now, acceptLegacyCheckpoint: false)
    XCTAssertFalse(exists(directory, LatencyBenchmarkStore.logFilename))
    try await store.checkpoint(record)
    try await store.discardCheckpointAndPrune(now: now)
    XCTAssertFalse(exists(directory, LatencyBenchmarkStore.activeFilename))
  }

  @MainActor
  func testDisabledStartupPrunesBothStreamsAndArchivesWithoutRecoveringCheckpoint() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = LatencyBenchmarkStore(directoryURL: directory)
    try await store.checkpoint(storedRecord())
    let oldDate = now.addingTimeInterval(-366 * 86_400)
    let expired = storedRecord(startedAt: oldDate)
    let fresh = storedRecord()
    let encoder = DiagnosticsJSON.encoder()
    let newline = Data([0x0A])
    let freshInteraction = try encoder.encode(fresh) + newline
    let mixedInteractions = try encoder.encode(expired) + newline + freshInteraction
    let freshRuntime = runtime(now) + newline
    let mixedRuntime = runtime(oldDate) + newline + freshRuntime
    let interactionArchive = directory.appending(
      path: "Archives/interactions-v1-1-\(UUID().uuidString).jsonl")
    let runtimeArchive = directory.appending(
      path: "Archives/runtime-v1-1-\(UUID().uuidString).jsonl")
    let streams = [
      (directory.appending(path: LatencyBenchmarkStore.logFilename), mixedInteractions, freshInteraction),
      (directory.appending(path: LatencyBenchmarkStore.runtimeFilename), mixedRuntime, freshRuntime),
      (interactionArchive, mixedInteractions, freshInteraction),
      (runtimeArchive, mixedRuntime, freshRuntime),
    ]
    for (url, mixed, _) in streams { try mixed.write(to: url) }
    let expiredArchive = directory.appending(
      path: "Archives/runtime-v1-2-\(UUID().uuidString).jsonl")
    try (runtime(oldDate) + newline).write(to: expiredArchive)

    let recorder = LatencyBenchmarkRecorder(directoryURL: directory, wallNow: { self.now }, enabled: false)
    await recorder.flushForTesting()

    for (url, _, expected) in streams {
      XCTAssertEqual(try Data(contentsOf: url), expected, url.lastPathComponent)
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: expiredArchive.path))
    XCTAssertFalse(exists(directory, LatencyBenchmarkStore.activeFilename))
    XCTAssertFalse(recorder.isRecording)
  }

  @MainActor
  func testDisabledStartupDoesNotCreateDiagnosticsDirectory() async {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let recorder = LatencyBenchmarkRecorder(directoryURL: directory, enabled: false)
    await recorder.flushForTesting()
    XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
  }

  func testDiscardCheckpointAndPruneEnforcesStorageCap() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let seedStore = LatencyBenchmarkStore(directoryURL: directory)
    try await seedStore.appendRuntime(runtime(now), now: now)
    try await seedStore.checkpoint(storedRecord())
    let store = LatencyBenchmarkStore(directoryURL: directory, maxTotalBytes: 1)

    try await store.discardCheckpointAndPrune(now: now)

    XCTAssertFalse(exists(directory, LatencyBenchmarkStore.runtimeFilename))
    XCTAssertFalse(exists(directory, LatencyBenchmarkStore.activeFilename))
    XCTAssertFalse(exists(directory, LatencyBenchmarkStore.logFilename))
  }

  func testRuntimeOnlyPrunesAgeAndCapsIncludingProtectedCheckpoint() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = LatencyBenchmarkStore(directoryURL: directory, rotationBytes: 1,
                                      maxTotalBytes: 2_000, retentionDays: 2)
    try await store.appendRuntime(runtime(now), now: now)
    try await store.appendRuntime(runtime(now), now: now)
    XCTAssertEqual(try archives(directory).count, 1)
    let later = now.addingTimeInterval(3 * 86_400)
    try await store.appendRuntime(runtime(later), now: later)
    XCTAssertEqual(try archives(directory).count, 0)
    XCTAssertEqual(try Data(contentsOf: directory.appending(path: LatencyBenchmarkStore.runtimeFilename))
      .split(separator: 0x0A).count, 1)
    let tightStore = LatencyBenchmarkStore(directoryURL: directory, maxTotalBytes: 1)
    try await tightStore.checkpoint(storedRecord())
    XCTAssertFalse(exists(directory, LatencyBenchmarkStore.runtimeFilename), "Checkpoint writes also enforce the cap")
    try await tightStore.appendRuntime(runtime(later), now: later)
    XCTAssertTrue(exists(directory, LatencyBenchmarkStore.activeFilename))
    XCTAssertFalse(exists(directory, LatencyBenchmarkStore.runtimeFilename))
  }

  func testMalformedPartialTailIsSeparatedAndEventuallyExpires() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = LatencyBenchmarkStore(directoryURL: directory, retentionDays: 2)
    try await store.recoverAndPrune(now: now)
    let url = directory.appending(path: LatencyBenchmarkStore.runtimeFilename)
    try Data("{partial".utf8).write(to: url)
    try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: url.path)
    try await store.appendRuntime(runtime(now), now: now)
    let lines = try Data(contentsOf: url).split(separator: 0x0A)
    XCTAssertEqual(lines.count, 2)
    XCTAssertEqual(String(decoding: lines[0], as: UTF8.self), "{partial")
    XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(lines[1])))
    let later = now.addingTimeInterval(3 * 86_400)
    try await store.appendRuntime(runtime(later), now: later)
    XCTAssertFalse(String(decoding: try Data(contentsOf: url), as: UTF8.self).contains("partial"))
  }

  func testClearPreservesCheckpointAndUnrelatedFiles() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = LatencyBenchmarkStore(directoryURL: directory, rotationBytes: 1)
    try await store.checkpoint(storedRecord())
    try await store.appendRuntime(runtime(now), now: now)
    try await store.appendRuntime(runtime(now), now: now)
    let unrelated = directory.appending(path: "Archives/unrelated.jsonl")
    try Data("keep".utf8).write(to: unrelated)
    try await store.clearCompletedHistory()
    XCTAssertTrue(exists(directory, LatencyBenchmarkStore.activeFilename))
    XCTAssertFalse(exists(directory, LatencyBenchmarkStore.runtimeFilename))
    XCTAssertEqual(try archives(directory).map(\.lastPathComponent), ["unrelated.jsonl"])
    XCTAssertEqual(try String(contentsOf: unrelated, encoding: .utf8), "keep")
    let permissions = try FileManager.default.attributesOfItem(
      atPath: directory.appending(path: LatencyBenchmarkStore.activeFilename).path)[.posixPermissions] as? NSNumber
    XCTAssertEqual(permissions?.intValue, 0o600)
  }

  func testRecoveryDiscardsMalformedAndOversizedCheckpoints() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = LatencyBenchmarkStore(directoryURL: directory)
    try await store.recoverAndPrune(now: now)
    let active = directory.appending(path: LatencyBenchmarkStore.activeFilename)
    for data in [Data("{partial".utf8), Data(repeating: 0x20, count: 1_048_577)] {
      try data.write(to: active)
      try await store.recoverAndPrune(now: now)
      XCTAssertFalse(exists(directory, LatencyBenchmarkStore.activeFilename))
      XCTAssertFalse(exists(directory, LatencyBenchmarkStore.logFilename))
    }
  }

  func testSymlinkDestinationIsNotFollowed() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = LatencyBenchmarkStore(directoryURL: directory)
    try await store.recoverAndPrune(now: now)
    let target = directory.appending(path: "unrelated.txt")
    try Data("keep".utf8).write(to: target)
    try FileManager.default.createSymbolicLink(
      at: directory.appending(path: LatencyBenchmarkStore.runtimeFilename), withDestinationURL: target)
    do {
      try await store.appendRuntime(runtime(now), now: now)
      XCTFail("Symlink writes must fail")
    } catch {}
    XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "keep")
  }

  private func temporaryDirectory() -> URL {
    let resolved = realpath(FileManager.default.temporaryDirectory.path, nil)!
    defer { free(resolved) }
    return URL(fileURLWithPath: String(cString: resolved)).appending(path: "DiagnosticsStoreTests-\(UUID().uuidString)")
  }

  private func exists(_ directory: URL, _ name: String) -> Bool {
    FileManager.default.fileExists(atPath: directory.appending(path: name).path)
  }

  private func archives(_ directory: URL) throws -> [URL] {
    try FileManager.default.contentsOfDirectory(at: directory.appending(path: "Archives"),
                                              includingPropertiesForKeys: nil)
  }

  private func runtime(_ date: Date) -> Data {
    Data("{\"schemaVersion\":1,\"timestamp\":\"\(ISO8601DateFormatter().string(from: date))\",\"event\":\"runtime_started\"}".utf8)
  }

  private func storedRecord(startedAt: Date? = nil) -> LatencyBenchmarkRecord {
    let date = startedAt ?? now
    return LatencyBenchmarkRecord(
      schemaVersion: 1, interactionID: UUID(), startedAt: date,
      lastCheckpointAt: date, endedAt: date,
      environment: BenchmarkEnvironment(appVersion: nil, appBuild: nil,
                                        macOSVersion: "TestOS", architecture: "arm64"),
      milestonesMS: [BenchmarkMilestone.terminal.rawValue: 1],
      durationsMS: BenchmarkDurations(totalMS: 1), workload: BenchmarkWorkload(),
      stt: BenchmarkSTTMetadata(model: "stt-rt-v5"),
      cleanup: BenchmarkCleanupMetadata(mode: .faithful,
        requestedModel: CleanupModel.defaultModel.rawValue, requestedReasoningEffort: nil,
        requestedProviderTag: nil, zeroDataRetentionRequired: nil),
      outcome: BenchmarkOutcome(terminalResult: .inserted, failureStage: nil,
                                failureCategory: nil, httpStatus: nil))
  }
}

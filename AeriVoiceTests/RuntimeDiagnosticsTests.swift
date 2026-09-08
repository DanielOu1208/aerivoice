import Darwin
import Darwin
import Foundation
import XCTest

@testable import AeriVoice

@MainActor
final class RuntimeDiagnosticsTests: XCTestCase {
  func testCPUUnitsAndCounterResetHandling() throws {
    XCTAssertEqual(DiagnosticsClock.milliseconds(24_000_000, numer: 125, denom: 3), 1_000)
    let before = snapshot(at: 100)
    let after = snapshot(at: 200)
    let interval = try XCTUnwrap(ResourceInterval(from: before, to: after))
    XCTAssertEqual(interval.elapsedMS, 100)
    XCTAssertEqual(interval.cpuMS, 15)
    XCTAssertEqual(interval.averageCPUPercent, 15)
    XCTAssertNil(ResourceInterval(from: after, to: before))
    XCTAssertNil(ResourceInterval(from: before, to: before))
  }

  func testNativeCountersMatchGetrusageAndContainExecutableIdentity() throws {
    let value = try XCTUnwrap(ProcessResourceSampler.usage(for: getpid()))
    var traditional = rusage()
    XCTAssertEqual(getrusage(RUSAGE_SELF, &traditional), 0)
    let referenceMS = Double(traditional.ru_utime.tv_sec) * 1_000 + Double(traditional.ru_utime.tv_usec) / 1_000
    XCTAssertEqual(DiagnosticsClock.milliseconds(value.ri_user_time), referenceMS, accuracy: 20)
    XCTAssertGreaterThan(value.ri_phys_footprint, 0)
    XCTAssertGreaterThanOrEqual(value.ri_lifetime_max_phys_footprint, value.ri_phys_footprint)
    XCTAssertNotNil(ProcessResourceSampler.executableUUID)
  }

  func testLaunchContextCountsAttemptsAndUsesActualShortcutResult() async throws {
    let harness = Harness()
    defer { harness.remove() }
    harness.runtime.shortcutAvailable(false)
    harness.runtime.shortcutAvailable(true)
    harness.runtime.finishInitialization()
    harness.clock.ms = 1_100
    harness.begin()
    let firstID = harness.runtime.currentInteractionID
    harness.benchmark.begin(enabled: true, cleanupMode: .faithful, cleanupConfiguration: harness.preferences.cleanupConfiguration)
    XCTAssertEqual(harness.runtime.currentInteractionID, firstID, "Duplicate begin must not change identity")
    harness.clock.ms = 1_300
    harness.benchmark.finish(.failed, stage: .readiness, category: .missingCredential)
    harness.runtime.phaseChanged(.idle)
    harness.clock.ms = 1_800
    harness.begin()
    harness.benchmark.finish(.cancelled)
    await harness.runtime.flushForTesting()
    let interactions = try harness.interactions()
    XCTAssertEqual(interactions.count, 2)
    guard interactions.count == 2 else { return }
    XCTAssertEqual(interactions[0].context?.activationIndex, 1)
    XCTAssertEqual(interactions[0].context?.sinceLaunchMS, 1_100)
    XCTAssertEqual(interactions[1].context?.activationIndex, 2)
    XCTAssertEqual(interactions[1].context?.sincePreviousInteractionMS, 500)
    XCTAssertEqual(interactions[0].context?.launchID, interactions[1].context?.launchID)
    XCTAssertEqual(interactions[0].interactionID, firstID)
    let events = try harness.records().map(\.event)
    XCTAssertTrue(events.contains(.shortcutUnavailable))
    XCTAssertTrue(events.contains(.shortcutEnabled))
  }

  func testPreparationSettingsAndSleepAreNotIdleAndResetIntervals() async throws {
    let harness = Harness()
    defer { harness.remove() }
    let token = harness.runtime.beginPreparation()
    harness.runtime.finishInitialization()
    XCTAssertEqual(harness.runtime.activity, .preparing)
    harness.runtime.finishPreparation(token, result: .failed)
    XCTAssertEqual(harness.runtime.activity, .idle)
    await harness.runtime.flushForTesting()
    harness.clock.ms += 100
    harness.runtime.requestResourceSample()
    await harness.runtime.flushForTesting()
    XCTAssertNotNil(try harness.records().last(where: { $0.resources != nil })?.resourceInterval)
    harness.runtime.setSettingsVisible(true)
    XCTAssertEqual(harness.runtime.activity, .settings)
    harness.runtime.setSettingsVisible(false)
    harness.runtime.willSleep()
    XCTAssertEqual(harness.runtime.activity, .sleeping)
    await harness.runtime.flushForTesting()
    let count = harness.sampler.calls
    harness.runtime.requestResourceSample()
    await harness.runtime.flushForTesting()
    XCTAssertEqual(harness.sampler.calls, count)
    harness.clock.ms += 50_000
    harness.runtime.didWake()
    await harness.runtime.flushForTesting()
    XCTAssertNil(try harness.records().last(where: { $0.resources != nil })?.resourceInterval)
    harness.clock.ms += 20
    harness.begin()
    harness.benchmark.finish(.cancelled)
    await harness.runtime.flushForTesting()
    XCTAssertEqual(try harness.interactions().last?.context?.sinceWakeMS, 20)
  }

  func testDisabledStartupCreatesNoFilesAndEnableDoesNotInventLaunch() async throws {
    let harness = Harness(enabled: false)
    defer { harness.remove() }
    harness.runtime.finishInitialization()
    harness.begin()
    harness.benchmark.finish(.cancelled)
    harness.runtime.phaseChanged(.idle)
    await harness.runtime.flushForTesting()
    XCTAssertEqual(harness.sampler.calls, 0)
    XCTAssertFalse(FileManager.default.fileExists(atPath: harness.directory.path))
    harness.preferences.latencyLogging = true
    await harness.runtime.flushForTesting()
    let events = try harness.records().map(\.event)
    XCTAssertTrue(events.contains(.loggingEnabled))
    XCTAssertFalse(events.contains(.initializationStarted))
    XCTAssertFalse(events.contains(.initializationFinished))
  }

  func testOptOutDiscardsActiveCheckpointAndRevokesDurableGeneration() async throws {
    let harness = Harness()
    defer { harness.remove() }
    harness.runtime.finishInitialization()
    harness.begin()
    await harness.runtime.flushForTesting()
    let oldGeneration = harness.preferences.diagnosticsGeneration
    harness.preferences.latencyLogging = false
    XCTAssertNotEqual(harness.preferences.diagnosticsGeneration, oldGeneration)
    XCTAssertFalse(harness.preferences.acceptsLegacyDiagnosticCheckpoint)
    harness.benchmark.mark(.captureStarted)
    harness.benchmark.finish(.cancelled)
    await harness.runtime.flushForTesting()
    XCTAssertFalse(FileManager.default.fileExists(atPath: harness.directory.appending(path: LatencyBenchmarkStore.activeFilename).path))
    XCTAssertEqual(try harness.records().last?.event, .loggingDisabled)
    XCTAssertEqual(try harness.interactions().count, 0)
    harness.preferences.latencyLogging = true
    harness.begin()
    harness.benchmark.finish(.cancelled)
    await harness.runtime.flushForTesting()
    XCTAssertEqual(try harness.interactions().count, 1)
    XCTAssertEqual(try harness.interactions().first?.recordingGeneration, harness.preferences.diagnosticsGeneration)
  }

  func testUnavailableSampleDoesNotBecomeZeroAndLogsStayContentFree() async throws {
    let harness = Harness(unavailable: true)
    defer { harness.remove() }
    harness.preferences.vocabulary = "PRIVATE-VOCABULARY-MUST-NOT-APPEAR"
    harness.runtime.finishInitialization()
    harness.begin()
    harness.benchmark.recordRawCharacters(28)
    harness.benchmark.finish(.emptyTranscript)
    await harness.runtime.flushForTesting()
    let records = try harness.records()
    XCTAssertTrue(records.contains { $0.event == .resourceUnavailable && $0.resources == nil })
    let data = try Data(contentsOf: harness.directory.appending(path: LatencyBenchmarkStore.runtimeFilename))
    let text = String(decoding: data, as: UTF8.self)
    for forbidden in ["PRIVATE-VOCABULARY", "vocabulary", "apiKey", "clipboard", "deviceID", "hostname"] {
      XCTAssertFalse(text.contains(forbidden))
    }
  }

  func testWritesAreBoundedAndOptOutInvalidatesQueuedCollection() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let writer = DiagnosticsWriteQueue(directoryURL: directory)
    let gate = WriteGate()
    writer.enqueue(control: true) { _ in await gate.wait() }
    for _ in 0..<150 {
      writer.enqueue { store in try await store.appendRuntime(Data("{}".utf8), now: Date()) }
    }
    XCTAssertGreaterThan(writer.droppedWrites, 0)
    writer.revokePendingCollection()
    await gate.open()
    await writer.flush()
    XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
  }

  func testTimestampCodecKeepsMillisecondsAndReadsLegacy() throws {
    let value = Date(timeIntervalSince1970: 2_000_000_000.125)
    let data = try DiagnosticsJSON.encoder().encode(value)
    XCTAssertEqual(try DiagnosticsJSON.decoder().decode(Date.self, from: data), value)
    XCTAssertNotNil(DiagnosticsJSON.date("2033-05-18T03:33:20Z"))
  }

  func testSettingsEventContainsOnlyChangesToMeasuredSettings() async throws {
    let harness = Harness()
    defer { harness.remove() }
    harness.preferences.vocabulary = "PRIVATE-CONTENT"
    harness.runtime.settingsChanged()
    harness.preferences.soundCues.toggle()
    harness.runtime.settingsChanged()
    harness.runtime.settingsChanged()
    await harness.runtime.flushForTesting()
    XCTAssertEqual(try harness.records().filter { $0.event == .settingsChanged }.count, 1)
  }

  func testTerminalResultSurvivesRoutineWriteBacklog() async throws {
    let harness = Harness()
    defer { harness.remove() }
    await harness.runtime.flushForTesting()
    let gate = WriteGate()
    let writer = harness.runtime.writer
    writer.enqueue(control: true) { _ in await gate.wait() }
    for _ in 0..<150 { writer.enqueue { _ in } }
    harness.begin()
    harness.benchmark.finish(.cancelled)
    await gate.open()
    await harness.runtime.flushForTesting()
    XCTAssertGreaterThan(writer.droppedWrites, 0)
    XCTAssertEqual(try harness.interactions().first?.outcome?.terminalResult, .cancelled)
  }

  func testClearInvalidatesPendingResourceSampleAndBaseline() async throws {
    let harness = Harness()
    defer { harness.remove() }
    harness.runtime.finishInitialization()
    await harness.runtime.flushForTesting()
    harness.runtime.requestResourceSample()
    harness.benchmark.clearCompletedHistory()
    await harness.runtime.flushForTesting()
    XCTAssertTrue(try harness.records().isEmpty)
    harness.clock.ms += 100
    harness.runtime.requestResourceSample()
    await harness.runtime.flushForTesting()
    XCTAssertNotNil(try harness.records().last?.resources)
    XCTAssertNil(try harness.records().last?.resourceInterval)
  }
}

@MainActor
private final class Harness {
  let directory = temporaryDirectory()
  let clock = DiagnosticTestClock()
  let sampler: DiagnosticTestSampler
  let preferences: AppPreferences
  let runtime: RuntimeDiagnosticsRecorder
  let benchmark: LatencyBenchmarkRecorder
  private let suite = "RuntimeDiagnosticsTests-\(UUID().uuidString)"

  init(enabled: Bool = true, unavailable: Bool = false) {
    let defaults = UserDefaults(suiteName: suite)!
    defaults.set(enabled, forKey: "latencyLogging")
    preferences = AppPreferences(defaults: defaults)
    sampler = DiagnosticTestSampler(clock: clock, unavailable: unavailable)
    let writer = DiagnosticsWriteQueue(directoryURL: directory)
    let preferences = preferences
    let clock = clock
    let environment = BenchmarkEnvironment(appVersion: "1", appBuild: "test", macOSVersion: "TestOS", architecture: "arm64")
    runtime = RuntimeDiagnosticsRecorder(
      enabled: enabled, writer: writer, launchStartedMS: 0, environment: environment,
      settings: { DiagnosticSettings(preferences) }, sampler: sampler, audioRoute: { nil },
      nowMS: { clock.ms }, wallNow: { clock.date }, scheduleTimer: false)
    benchmark = LatencyBenchmarkRecorder(
      directoryURL: directory, monotonicNowMS: { clock.ms }, wallNow: { clock.date },
      environment: environment, enabled: enabled,
      recordingGeneration: preferences.diagnosticsGeneration, writer: writer, runtime: runtime)
    preferences.onDiagnosticsLoggingChange = { [weak benchmark] enabled in
      benchmark?.setEnabled(enabled, recordingGeneration: preferences.diagnosticsGeneration)
    }
  }
  func begin() {
    benchmark.begin(enabled: preferences.latencyLogging, cleanupMode: .faithful,
                    cleanupConfiguration: preferences.cleanupConfiguration)
  }
  func records() throws -> [RuntimeDiagnosticRecord] {
    try records(named: LatencyBenchmarkStore.runtimeFilename)
  }
  func interactions() throws -> [LatencyBenchmarkRecord] {
    try records(named: LatencyBenchmarkStore.logFilename)
  }
  private func records<T: Decodable>(named name: String) throws -> [T] {
    let url = directory.appending(path: name)
    guard FileManager.default.fileExists(atPath: url.path) else { return [] }
    return try Data(contentsOf: url).split(separator: 10).map {
      try DiagnosticsJSON.decoder().decode(T.self, from: Data($0))
    }
  }
  func remove() {
    preferences.onDiagnosticsLoggingChange = nil
    runtime.terminate()
    runtime.writer.flushBeforeTermination()
    UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    try? FileManager.default.removeItem(at: directory)
  }
}

private func temporaryDirectory() -> URL {
  let resolved = realpath(FileManager.default.temporaryDirectory.path, nil)!
  defer { free(resolved) }
  return URL(fileURLWithPath: String(cString: resolved))
    .appending(path: "RuntimeDiagnosticsTests-\(UUID().uuidString)")
}

private func snapshot(at ms: Double) -> ProcessResourceSnapshot {
  ProcessResourceSnapshot(
    sampledAt: Date(timeIntervalSince1970: 2_000_000_000 + ms / 1_000), uptimeMS: ms,
    userCPUMS: ms / 10, systemCPUMS: ms / 20, physicalFootprintBytes: 10_000,
    lifetimePeakFootprintBytes: 15_000, diskReadBytes: UInt64(ms), diskWriteBytes: UInt64(ms),
    idleWakeups: UInt64(ms), interruptWakeups: UInt64(ms), thermalState: "nominal",
    lowPowerMode: false, powerSource: "ac")
}

private final class DiagnosticTestClock: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Double = 0
  var ms: Double {
    get { lock.withLock { value } }
    set { lock.withLock { value = newValue } }
  }
  var date: Date { Date(timeIntervalSince1970: 2_000_000_000 + ms / 1_000) }
}

private final class DiagnosticTestSampler: ResourceSampling, @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  private let clock: DiagnosticTestClock
  private let unavailable: Bool
  var calls: Int { lock.withLock { count } }
  init(clock: DiagnosticTestClock, unavailable: Bool) { self.clock = clock; self.unavailable = unavailable }
  func sample() -> ProcessResourceSnapshot? {
    lock.withLock { count += 1 }
    return unavailable ? nil : snapshot(at: clock.ms)
  }
}

private actor WriteGate {
  private var isOpen = false
  private var waiter: CheckedContinuation<Void, Never>?
  func wait() async {
    if isOpen { return }
    await withCheckedContinuation { waiter = $0 }
  }
  func open() { isOpen = true; waiter?.resume(); waiter = nil }
}

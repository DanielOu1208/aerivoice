import Foundation
import XCTest
@testable import AeriVoice

@MainActor
final class LocalSpeechRuntimeTests: XCTestCase {
  func testSilenceDoesNotReturnACompletedTranscript() async throws {
    let engine = BlockingLocalEngine(finalText: "  ")
    let runtime = LocalSpeechRuntime(makeEngine: { engine })
    try await runtime.load(from: URL(fileURLWithPath: "/unused"))
    let client = LocalRealtimeClient(runtime: runtime)
    try await client.connect(configuration: TranscriptionConfiguration(provider: .local), apiKey: "",
      vocabulary: [], sessionID: DictationSessionID())
    do { _ = try await client.finish(); XCTFail("Silence must stop the pipeline") }
    catch AppError.emptyTranscript {} catch { XCTFail("Unexpected error: \(error)") }
  }

  func testPCMConversionAndIncompleteSample() throws {
    XCTAssertEqual(try LocalRealtimeClient.samples(from: Data([0, 128, 0, 0, 255, 127])),
                   [-1, 0, Float(32767) / 32768])
    XCTAssertThrowsError(try LocalRealtimeClient.samples(from: Data([0])))
    XCTAssertNil(TranscriptionProvider.local.credentialKind)
  }

  func testCancellationDrainsBeforeResetAndNextDictionary() async throws {
    let engine = BlockingLocalEngine()
    let runtime = LocalSpeechRuntime(makeEngine: { engine })
    try await runtime.load(from: URL(fileURLWithPath: "/unused"))
    let first = UUID(), second = UUID()
    try await runtime.begin(first, vocabulary: ["AeriVoice"])
    let processing = Task { try await runtime.process([0], id: first) }
    await engine.waitForProcessing()
    runtime.cancel(first)
    let next = Task { try await runtime.begin(second, vocabulary: ["Nemotron"]) }
    await engine.releaseProcessing()
    do { _ = try await processing.value; XCTFail("Cancelled session returned text") }
    catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
    try await next.value
    let events = await engine.events
    XCTAssertEqual(events, ["load", "reset", "vocab:AeriVoice", "process", "processed", "reset", "reset", "vocab:Nemotron"])
    let final = try await runtime.finish(second)
    XCTAssertEqual(final, "final")
  }

  func testUnloadingDefersUntilActiveRecordingFinishes() async throws {
    let engine = BlockingLocalEngine()
    let runtime = LocalSpeechRuntime(makeEngine: { engine })
    try await runtime.load(from: URL(fileURLWithPath: "/unused"))
    let session = UUID()
    try await runtime.begin(session, vocabulary: [])
    await runtime.unload()
    XCTAssertFalse(runtime.isReady)
    XCTAssertTrue(runtime.hasActiveSession)
    _ = try await runtime.finish(session)
    XCTAssertFalse(runtime.hasActiveSession)
    try await runtime.load(from: URL(fileURLWithPath: "/unused"))
    let events = await engine.events
    XCTAssertEqual(events.filter { $0 == "load" }.count, 2)
  }
}

private actor BlockingLocalEngine: LocalSpeechEngine {
  let finalText: String
  init(finalText: String = "final") { self.finalText = finalText }
  var events: [String] = []
  var started: CheckedContinuation<Void, Never>?
  var pending: CheckedContinuation<Void, Never>?
  func load(from directory: URL) async throws { events.append("load") }
  func reset() async { events.append("reset") }
  func setVocabulary(_ words: [String]) async { events.append("vocab:" + words.joined(separator: ",")) }
  func process(_ samples: [Float]) async throws -> String {
    events.append("process")
    await withCheckedContinuation { continuation in
      pending = continuation
      started?.resume(); started = nil
    }
    events.append("processed")
    return "stale"
  }
  func waitForProcessing() async {
    if pending != nil { return }
    await withCheckedContinuation { started = $0 }
  }
  func releaseProcessing() { pending?.resume(); pending = nil }
  func finish() async throws -> String { finalText }
}

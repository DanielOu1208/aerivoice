import AVFoundation
import Foundation
import XCTest

@testable import AeriVoice

@MainActor
final class SyntheticPipelineLiveBenchmarkTests: XCTestCase {
  private struct Configuration: Decodable {
    let sampleCount: Int
    let idleSeconds: Double
    let audioPath: String
    let outputPath: String
    let credentialPipePath: String
    let compareWarming: Bool?
  }

  private struct Durations: Encodable {
    let sonioxConnectMS: Double?
    let audioStreamingMS: Double?
    let sonioxFinalizeMS: Double?
    let cerebrasCleanupMS: Double?
    let endOfAudioToCleanedMS: Double?
    let totalMS: Double
  }

  private struct STTRecord: Encodable {
    let provider: String
    let model: String
    let audioEncoding: String
    let audioBytes: Int
    let audioDurationMS: Double
    let finalAudioProcessedMS: Double?
    let totalAudioProcessedMS: Double?
    let transcriptCharacters: Int?
  }

  private struct CleanupRecord: Encodable {
    let provider: String
    let requestedModel: String
    let actualModel: String?
    let httpStatus: Int?
    let promptTokens: Int?
    let completionTokens: Int?
    let cachedPromptTokens: Int?
    let requestEncodingMS: Double?
    let networkRequestMS: Double?
    let responseDecodingMS: Double?
    let providerTiming: CleanupProviderTimingMetrics?
    let networkTiming: CleanupNetworkTimingMetrics?
    let cleanedCharacters: Int?
  }

  private struct Outcome: Encodable {
    let pipelineSucceeded: Bool
    let transcriptionCorrectnessPassed: Bool
    let cleanupCorrectnessPassed: Bool
    let correctnessFailures: [String]
    let failureStage: String?
    let failureCategory: String?
  }

  private struct Record: Encodable {
    let schemaVersion: Int
    let benchmarkKind: String
    let fixtureID: String
    let sampleIndex: Int
    let startedAt: Date
    let configuredIdleSeconds: Double
    let warmingEnabled: Bool
    let isolatedConnection: Bool
    let comparisonPair: Int?
    let durationsMS: Durations
    let stt: STTRecord
    let cleanup: CleanupRecord
    let outcome: Outcome
  }

  private enum SyntheticBenchmarkError: Error {
    case asynchronousSonioxFailure
  }

  private static let configurationURL = URL(
    fileURLWithPath: "/tmp/aerivoice-synthetic-pipeline-benchmark.plist")
  private static let fixtureID = "macos-samantha-en-us-v1"
  private static let requiredFragmentGroups = [
    ["synthetic"], ["benchmark"], ["draft"], ["friday"], ["morning"],
  ]

  func testCorrectnessOracleAcceptsPunctuationAndCaseChanges() {
    XCTAssertEqual(
      Self.correctnessFailures(
        in: "Synthetic benchmark: please send the draft on Friday morning.", prefix: "stt"),
      [])
    XCTAssertEqual(
      Self.correctnessFailures(in: "Synthetic benchmark on Friday.", prefix: "cleanup"),
      ["cleanup-missing-fragment-group-3", "cleanup-missing-fragment-group-5"])
  }

  func testSyntheticSonioxCerebrasPipeline() async throws {
    guard let configurationData = try? Data(contentsOf: Self.configurationURL) else {
      throw XCTSkip(
        "Run scripts/run-synthetic-pipeline-benchmark.sh to enable the live benchmark.")
    }
    try? FileManager.default.removeItem(at: Self.configurationURL)
    let configuration = try PropertyListDecoder().decode(
      Configuration.self, from: configurationData)
    guard configuration.sampleCount > 0, configuration.idleSeconds >= 0 else {
      XCTFail("The synthetic pipeline benchmark configuration is invalid.")
      return
    }

    let credentials = try Self.loadCredentials(
      from: URL(fileURLWithPath: configuration.credentialPipePath))
    let sonioxKey = credentials.soniox
    let cerebrasKey = credentials.cerebras

    let audioURL = URL(
      fileURLWithPath: NSString(string: configuration.audioPath).expandingTildeInPath)
    let audio = try Self.loadPCM16Audio(from: audioURL)
    let outputURL = URL(
      fileURLWithPath: NSString(string: configuration.outputPath).expandingTildeInPath)
    try Self.prepareOutputFile(at: outputURL)

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let cleaner = CerebrasCleanupClient()
    let compareWarming = configuration.compareWarming == true
    let totalSamples = configuration.sampleCount * (compareWarming ? 2 : 1)

    for sampleIndex in 1...totalSamples {
      try await Task.sleep(for: .seconds(configuration.idleSeconds))
      // Each adjacent pair has the same input. Reverse its order on alternate pairs.
      let pairIndex = (sampleIndex - 1) / 2
      let warmingEnabled = !compareWarming || (sampleIndex - 1) % 2 == pairIndex % 2
      let session: URLSession?
      if compareWarming {
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.requestCachePolicy = .reloadIgnoringLocalCacheData
        sessionConfiguration.waitsForConnectivity = false
        session = URLSession(configuration: sessionConfiguration)
      } else {
        session = nil
      }
      let sampleCleaner = session.map { CerebrasCleanupClient(session: $0) } ?? cleaner
      let record = await runSample(
        index: sampleIndex, audio: audio, cleaner: sampleCleaner, sonioxKey: sonioxKey,
        cerebrasKey: cerebrasKey, configuredIdleSeconds: configuration.idleSeconds,
        warmingEnabled: warmingEnabled, isolatedConnection: compareWarming,
        comparisonPair: compareWarming ? pairIndex + 1 : nil)
      session?.finishTasksAndInvalidate()
      try Self.append(record, encoder: encoder, to: outputURL)
      XCTAssertTrue(
        record.outcome.pipelineSucceeded,
        "Synthetic sample \(sampleIndex) failed at \(record.outcome.failureStage ?? "unknown") "
          + "(\(record.outcome.failureCategory ?? "unknown")).")
      XCTAssertTrue(
        record.outcome.transcriptionCorrectnessPassed,
        "Synthetic sample \(sampleIndex) failed content-free Soniox checks: "
          + "\(record.outcome.correctnessFailures.filter { $0.hasPrefix("stt-") }).")
      XCTAssertTrue(
        record.outcome.cleanupCorrectnessPassed,
        "Synthetic sample \(sampleIndex) failed content-free cleanup checks: "
          + "\(record.outcome.correctnessFailures.filter { $0.hasPrefix("cleanup-") }).")
    }

    print("AeriVoice synthetic pipeline benchmark: \(outputURL.path)")
  }

  private func runSample(
    index: Int, audio: Data, cleaner: CerebrasCleanupClient, sonioxKey: String,
    cerebrasKey: String, configuredIdleSeconds: Double, warmingEnabled: Bool,
    isolatedConnection: Bool, comparisonPair: Int?
  ) async -> Record {
    let clock = ContinuousClock()
    let sampleStarted = clock.now
    let startedAt = Date()
    let audioDurationMS = Double(audio.count) / 32.0
    var stage = "soniox-connect"
    var sonioxConnectMS: Double?
    var audioStreamingMS: Double?
    var sonioxFinalizeMS: Double?
    var cerebrasCleanupMS: Double?
    var endOfAudioToCleanedMS: Double?
    var latestUpdate: RealtimeTranscriptUpdate?
    var transcriptCharacters: Int?
    var cleanedCharacters: Int?
    var cleanupMetrics: CleanupRequestMetrics?
    var transcriptionPassed = false
    var cleanupPassed = false
    var pipelineSucceeded = false
    var correctnessFailures: [String] = []
    var failureStage: String?
    var failureCategory: String?

    let transcriber = SonioxRealtimeClient()
    var asynchronousSonioxFailure = false
    transcriber.onTranscript = { latestUpdate = $0 }
    transcriber.onError = { _ in asynchronousSonioxFailure = true }
    defer { transcriber.cancel() }

    let warmUpTask = Task {
      guard warmingEnabled else { return }
      await cleaner.warmUp(
        configuration: Self.cleanupConfiguration, apiKey: cerebrasKey)
    }

    do {
      let connectStarted = clock.now
      try await transcriber.connect(
        configuration: TranscriptionConfiguration(provider: .soniox), apiKey: sonioxKey,
        vocabulary: ["AeriVoice"], sessionID: DictationSessionID())
      sonioxConnectMS = Self.elapsedMilliseconds(from: connectStarted, to: clock.now)

      stage = "audio-stream"
      let streamingStarted = clock.now
      try await Self.streamInRealtime(audio, through: transcriber)
      audioStreamingMS = Self.elapsedMilliseconds(from: streamingStarted, to: clock.now)
      if asynchronousSonioxFailure { throw SyntheticBenchmarkError.asynchronousSonioxFailure }

      stage = "soniox-finalize"
      let endOfAudio = clock.now
      let transcript = try await transcriber.finish()
      sonioxFinalizeMS = Self.elapsedMilliseconds(from: endOfAudio, to: clock.now)
      transcriptCharacters = transcript.count
      let sttFailures = Self.correctnessFailures(in: transcript, prefix: "stt")
      correctnessFailures.append(contentsOf: sttFailures)
      transcriptionPassed = sttFailures.isEmpty

      stage = "cerebras-cleanup"
      await warmUpTask.value
      let cleanupStarted = clock.now
      let cleanup = try await cleaner.clean(
        transcript, mode: .faithful, configuration: Self.cleanupConfiguration,
        apiKey: cerebrasKey)
      cerebrasCleanupMS = Self.elapsedMilliseconds(from: cleanupStarted, to: clock.now)
      endOfAudioToCleanedMS = Self.elapsedMilliseconds(from: endOfAudio, to: clock.now)
      cleanupMetrics = cleanup.metrics
      cleanedCharacters = cleanup.text.count
      let cleanupFailures = Self.correctnessFailures(in: cleanup.text, prefix: "cleanup")
      correctnessFailures.append(contentsOf: cleanupFailures)
      cleanupPassed = cleanupFailures.isEmpty
      pipelineSucceeded = true
      if !transcriptionPassed || !cleanupPassed {
        failureStage = "content-validation"
        failureCategory = "required-fragment-missing"
      }
    } catch {
      warmUpTask.cancel()
      failureStage = stage
      failureCategory = Self.failureCategory(for: error)
      cleanupMetrics =
        (error as? ProviderHTTPError)?.cleanupMetrics
        ?? (error as? CleanupNetworkError)?.cleanupMetrics
    }

    return Record(
      schemaVersion: 1, benchmarkKind: "synthetic-soniox-cerebras", fixtureID: Self.fixtureID,
      sampleIndex: index, startedAt: startedAt, configuredIdleSeconds: configuredIdleSeconds,
      warmingEnabled: warmingEnabled, isolatedConnection: isolatedConnection,
      comparisonPair: comparisonPair,
      durationsMS: Durations(
        sonioxConnectMS: sonioxConnectMS, audioStreamingMS: audioStreamingMS,
        sonioxFinalizeMS: sonioxFinalizeMS, cerebrasCleanupMS: cerebrasCleanupMS,
        endOfAudioToCleanedMS: endOfAudioToCleanedMS,
        totalMS: Self.elapsedMilliseconds(from: sampleStarted, to: clock.now)),
      stt: STTRecord(
        provider: "soniox", model: TranscriptionProvider.soniox.modelID,
        audioEncoding: "pcm_s16le_16000", audioBytes: audio.count,
        audioDurationMS: audioDurationMS,
        finalAudioProcessedMS: latestUpdate?.finalAudioProcessedMS,
        totalAudioProcessedMS: latestUpdate?.totalAudioProcessedMS,
        transcriptCharacters: transcriptCharacters),
      cleanup: Self.cleanupRecord(from: cleanupMetrics, cleanedCharacters: cleanedCharacters),
      outcome: Outcome(
        pipelineSucceeded: pipelineSucceeded,
        transcriptionCorrectnessPassed: transcriptionPassed,
        cleanupCorrectnessPassed: cleanupPassed, correctnessFailures: correctnessFailures,
        failureStage: failureStage, failureCategory: failureCategory))
  }

  private static let cleanupConfiguration = CleanupConfiguration(
    model: .qwen38_27BCerebras, reasoningEffort: .none)

  private static func cleanupRecord(
    from metrics: CleanupRequestMetrics?, cleanedCharacters: Int?
  ) -> CleanupRecord {
    CleanupRecord(
      provider: "cerebras-direct", requestedModel: cleanupConfiguration.model.rawValue,
      actualModel: metrics?.actualModel, httpStatus: metrics?.httpStatus,
      promptTokens: metrics?.promptTokens, completionTokens: metrics?.completionTokens,
      cachedPromptTokens: metrics?.cachedPromptTokens,
      requestEncodingMS: metrics?.requestEncodingMS,
      networkRequestMS: metrics?.networkRequestMS,
      responseDecodingMS: metrics?.responseDecodingMS,
      providerTiming: metrics?.providerTiming, networkTiming: metrics?.networkTiming,
      cleanedCharacters: cleanedCharacters)
  }

  private static func loadPCM16Audio(from url: URL) throws -> Data {
    let file = try AVAudioFile(forReading: url)
    guard file.length > 0, file.length <= AVAudioFramePosition(UInt32.max),
      let input = AVAudioPCMBuffer(
        pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))
    else {
      throw CocoaError(.fileReadCorruptFile)
    }
    try file.read(into: input)
    guard let converter = PCM16AudioConverter(), let data = converter.convert(input), !data.isEmpty
    else {
      throw CocoaError(.fileReadCorruptFile)
    }
    return data
  }

  private static func loadCredentials(
    from pipeURL: URL
  ) throws -> (soniox: String, cerebras: String) {
    let handle = try FileHandle(forReadingFrom: pipeURL)
    defer { try? handle.close() }
    let data = try handle.readToEnd() ?? Data()
    let fields = data.split(separator: 0, omittingEmptySubsequences: false)
    guard fields.count >= 2,
      let soniox = String(data: fields[0], encoding: .utf8), !soniox.isEmpty,
      let cerebras = String(data: fields[1], encoding: .utf8), !cerebras.isEmpty
    else {
      throw CocoaError(.fileReadCorruptFile)
    }
    return (soniox, cerebras)
  }

  private static func streamInRealtime(
    _ audio: Data, through transcriber: SonioxRealtimeClient
  ) async throws {
    let bytesPerSecond = 32_000
    let frameBytes = 3_200
    let clock = ContinuousClock()
    let streamingStarted = clock.now
    var offset = 0
    while offset < audio.count {
      let end = min(offset + frameBytes, audio.count)
      let frame = audio.subdata(in: offset..<end)
      try await transcriber.send(
        RealtimeAudioFrame(audio: frame, queuedBytesAfterFrame: audio.count - end))
      offset = end
      let streamedNanoseconds = Int64(
        Double(offset) / Double(bytesPerSecond) * 1_000_000_000)
      try await clock.sleep(
        until: streamingStarted.advanced(by: .nanoseconds(streamedNanoseconds)))
    }
  }

  private static func correctnessFailures(in output: String, prefix: String) -> [String] {
    let normalized = output.folding(options: .diacriticInsensitive, locale: .current).lowercased()
    return requiredFragmentGroups.enumerated().compactMap { index, alternatives in
      alternatives.contains { normalized.contains($0.lowercased()) }
        ? nil : "\(prefix)-missing-fragment-group-\(index + 1)"
    }
  }

  private static func failureCategory(for error: Error) -> String {
    if let error = error as? ProviderHTTPError { return "http-\(error.statusCode)" }
    if let error = error as? CleanupNetworkError {
      return "network-\(error.code.rawValue)"
    }
    if let error = error as? URLError { return "network-\(error.code.rawValue)" }
    if error is SyntheticBenchmarkError { return "asynchronous-soniox-failure" }
    if error is CancellationError { return "cancelled" }
    return "unexpected-error"
  }

  private static func prepareOutputFile(at url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    if FileManager.default.fileExists(atPath: url.path) {
      try FileManager.default.removeItem(at: url)
    }
    guard
      FileManager.default.createFile(
        atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
    else {
      throw CocoaError(.fileWriteUnknown)
    }
  }

  private static func append(_ record: Record, encoder: JSONEncoder, to url: URL) throws {
    var line = try encoder.encode(record)
    line.append(0x0A)
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: line)
  }

  private static func elapsedMilliseconds(
    from start: ContinuousClock.Instant, to end: ContinuousClock.Instant
  ) -> Double {
    let components = start.duration(to: end).components
    return Double(components.seconds) * 1_000
      + Double(components.attoseconds) / 1_000_000_000_000_000
  }
}

import Foundation

enum EvalError: String, Error {
  case invalidScenario, invalidAudio, missingCredential, deadline, interrupted, internalFailure
}

struct EvalScenario: Decodable {
  let protocolVersion: Int
  let id: String?
  let kind: String
  let mode: String
  let audioPath: String?
  let transcript: String?
  let transcriptionProvider: String?
  let offlineMode: Bool?
  let localModel: String?
  let appleLocale: String?
  let localModelPath: String?
  let localModelVariant: String?
  let cleanupModel: String?
  let cleanupReasoning: String?
  let cleanupMode: String?
  let vocabulary: [String]?
  let prepared: Bool?
  let soundCues: Bool?
  let repetitions: Int?
  let deadlineS: Double?
  let postResultObservationMs: Double?
  let gapMs: Double?
  let sampleRate: Double?
  let channels: Int?
  let chunkFrames: Int?
  let cancelAfterMs: Double?
  let cancelSessions: [Int]?
  let controlled: ControlledResponses?

  var live: Bool { mode == "live" }
  var provider: TranscriptionProvider { TranscriptionProvider(rawValue: transcriptionProvider ?? "soniox")! }
  var localEngine: LocalTranscriptionModel { LocalTranscriptionModel(rawValue: localModel ?? "nemotron")! }
  var model: CleanupModel { CleanupModel(rawValue: cleanupModel ?? "qwen-3.8-27b")! }
  var configuration: CleanupConfiguration {
    CleanupConfiguration(model: model, reasoningEffort: cleanupReasoning.flatMap(CleanupReasoningEffort.init) ?? model.defaultReasoningEffort)
  }
  var cleaningMode: CleanupMode { CleanupMode(rawValue: cleanupMode ?? "Faithful")! }
  var count: Int { repetitions ?? 1 }
  var timeout: Double { deadlineS ?? 60 }
  var observationMS: Double { postResultObservationMs ?? 2_500 }
  var fixtureRate: Double { sampleRate ?? 48_000 }
  var fixtureChannels: Int { channels ?? 1 }
  var fixtureChunkFrames: Int { chunkFrames ?? 1_024 }
  var script: ControlledResponses { controlled ?? ControlledResponses() }
  var scriptedTranscript: String { script.transcript ?? transcript ?? "Hello, world." }

  func shouldCancel(session: Int, elapsedMS: Double) -> Bool {
    guard let cancelAfterMs, elapsedMS >= cancelAfterMs else { return false }
    return cancelSessions?.contains(session) ?? true
  }

  func validate() throws {
    guard protocolVersion == 1, ["pipeline", "transcription", "cleanup", "conversion", "stability"].contains(kind),
      ["live", "controlled"].contains(mode), count > 0, count <= 10_000,
      timeout.isFinite, timeout > 0, timeout <= 86_400,
      observationMS.isFinite, observationMS >= 0, observationMS <= 3_600_000,
      (gapMs ?? 0).isFinite, (gapMs ?? 0) >= 0,
      [16_000, 44_100, 48_000].contains(fixtureRate), [1, 2].contains(fixtureChannels),
      fixtureChunkFrames > 0, fixtureChunkFrames <= 16_384,
      TranscriptionProvider(rawValue: transcriptionProvider ?? "soniox") != nil,
      CleanupModel(rawValue: cleanupModel ?? "qwen-3.8-27b") != nil,
      CleanupMode(rawValue: cleanupMode ?? "Faithful") != nil
    else { throw EvalError.invalidScenario }
    guard LocalTranscriptionModel(rawValue: localModel ?? "nemotron") != nil else { throw EvalError.invalidScenario }
    if provider != .local,
       localModel != nil || appleLocale != nil || localModelPath != nil || localModelVariant != nil {
      throw EvalError.invalidScenario
    }
    if localEngine == .apple, localModelPath != nil || localModelVariant != nil { throw EvalError.invalidScenario }
    if localEngine != .apple, appleLocale != nil { throw EvalError.invalidScenario }
    if let appleLocale {
      guard !appleLocale.isEmpty, appleLocale.utf8.count <= 100,
            appleLocale.range(of: "^[A-Za-z]{2,8}([_-][A-Za-z0-9]{1,8})*$", options: .regularExpression) != nil
      else { throw EvalError.invalidScenario }
    }
    if offlineMode == true, provider != .local || kind == "cleanup" || kind == "conversion" { throw EvalError.invalidScenario }
    if let localModelVariant, !["560ms", "1120ms"].contains(localModelVariant) { throw EvalError.invalidScenario }
    if localModelVariant == "1120ms", localModelPath == nil { throw EvalError.invalidScenario }
    if let cleanupReasoning {
      guard let effort = CleanupReasoningEffort(rawValue: cleanupReasoning), model.supportedReasoningEfforts.contains(effort) else {
        throw EvalError.invalidScenario
      }
    }
    if let cancelSessions {
      guard kind != "conversion", cancelAfterMs != nil, !cancelSessions.isEmpty,
        Set(cancelSessions).count == cancelSessions.count,
        cancelSessions.allSatisfy({ (1...count).contains($0) }) else { throw EvalError.invalidScenario }
    }
    if let cancelAfterMs, !cancelAfterMs.isFinite || cancelAfterMs < 0 { throw EvalError.invalidScenario }
    if kind != "cleanup", audioPath == nil { throw EvalError.invalidScenario }
    if kind == "cleanup", transcript == nil { throw EvalError.invalidScenario }
    try script.validate()
    if provider == .local, script.fault == "malformed_stt" { throw EvalError.invalidScenario }
  }
}

struct ControlledResponses: Decodable, Sendable {
  var transcript: String? = nil
  var cleanupText: String? = nil
  var connectDelayMs: Double? = nil
  var finalizeDelayMs: Double? = nil
  var cleanupDelayMs: Double? = nil
  var fault: String? = nil
  var httpStatus: Int? = nil

  func validate() throws {
    for value in [connectDelayMs, finalizeDelayMs, cleanupDelayMs].compactMap({ $0 }) {
      guard value.isFinite, value >= 0, value <= 60_000 else { throw EvalError.invalidScenario }
    }
    if let fault, !["connection", "finalize_timeout", "malformed_stt", "cleanup_http", "cleanup_empty"].contains(fault) {
      throw EvalError.invalidScenario
    }
    if let httpStatus, !(400...599).contains(httpStatus) { throw EvalError.invalidScenario }
  }
}

/// Only this file writes stdout. Resource sampling and audio delivery use separate queues.
final class EvalEvents: @unchecked Sendable {
  private let lock = NSLock()
  private let origin = DiagnosticsClock.uptimeMS()
  private var currentSession = 0
  var elapsedMS: Double { DiagnosticsClock.uptimeMS() - origin }
  var session: Int { lock.withLock { currentSession } }

  func setSession(_ session: Int) { lock.withLock { currentSession = session } }

  func emit(_ type: String, _ data: [String: Any] = [:], at elapsed: Double? = nil, session: Int? = nil) {
    lock.withLock {
      let object: [String: Any] = ["protocol_version": 1, "type": type, "session": session ?? currentSession,
                                   "elapsed_ms": elapsed ?? elapsedMS, "data": data]
      guard let bytes = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
      FileHandle.standardOutput.write(bytes + Data([10]))
    }
  }

  static func object<T: Encodable>(_ value: T) -> Any {
    guard let bytes = try? JSONEncoder().encode(value),
      let object = try? JSONSerialization.jsonObject(with: bytes) else { return NSNull() }
    return object
  }
}

final class EvalResources {
  private var timer: DispatchSourceTimer?
  private let queue = DispatchQueue(label: "aerivoice.eval.resources", qos: .utility)
  private let events: EvalEvents

  init(events: EvalEvents) { self.events = events }

  func start() {
    let timer = DispatchSource.makeTimerSource(queue: queue)
    let events = events
    timer.setEventHandler { Self.record(events: events, boundary: "periodic") }
    timer.schedule(deadline: .now(), repeating: .milliseconds(100))
    self.timer = timer
    timer.resume()
  }

  func sample(_ boundary: String) {
    queue.sync { Self.record(events: events, boundary: boundary) }
  }

  private static func record(events: EvalEvents, boundary: String) {
    let before = events.elapsedMS
    guard let usage = ProcessResourceSampler.usage(for: getpid()) else {
      events.emit("resource_unavailable", ["boundary": boundary]); return
    }
    let sampled = events.elapsedMS
    events.emit("resource", [
      "cumulative_cpu_ms": DiagnosticsClock.milliseconds(usage.ri_user_time) + DiagnosticsClock.milliseconds(usage.ri_system_time),
      "physical_footprint_bytes": usage.ri_phys_footprint,
      "resident_bytes": usage.ri_resident_size,
      "peak_physical_footprint_bytes": usage.ri_lifetime_max_phys_footprint,
      "acquisition_ms": sampled - before, "boundary": boundary,
    ], at: sampled)
  }

  func stop() {
    timer?.cancel()
    timer = nil
    queue.sync {}
  }
}

struct EvalCredentials: CredentialReading {
  let values: [String: String]
  let controlled: Bool
  func value(for kind: CredentialKind) -> String? { controlled ? "eval-controlled-placeholder" : values[kind.rawValue] }

  static func read(controlled: Bool) throws -> Self {
    if controlled { return Self(values: [:], controlled: true) }
    guard let value = ProcessInfo.processInfo.environment["AERIVOICE_EVAL_CREDENTIAL_FD"],
      let fd = Int32(value), fd >= 3 else { throw EvalError.missingCredential }
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    var data = Data()
    while let chunk = try handle.read(upToCount: 4_096), !chunk.isEmpty {
      data.append(chunk)
      guard data.count <= 65_536 else { throw EvalError.missingCredential }
    }
    let values = try JSONDecoder().decode([String: String].self, from: data)
    guard values.values.allSatisfy({ value in
      !value.isEmpty && value.utf8.count <= 4_096 && value.utf8.allSatisfy { (33...126).contains($0) }
    }) else { throw EvalError.missingCredential }
    return Self(values: values, controlled: false)
  }
}

func evalFailure(_ error: Error) -> String {
  if let error = error as? EvalError { return error.rawValue }
  if error is CancellationError { return "cancelled" }
  if error is ProviderHTTPError { return "provider_http" }
  if error is CleanupNetworkError || error is URLError { return "network" }
  if error is DecodingError { return "malformed_response" }
  if let error = error as? AppError {
    switch error {
    case .connectionTimeout: return "connection_timeout"
    case .finalizeTimeout: return "finalize_timeout"
    case .emptyTranscript: return "empty_transcript"
    default: return "provider"
    }
  }
  return "internal_failure"
}

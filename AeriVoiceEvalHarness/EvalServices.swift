import Foundation

@MainActor
final class EvalBenchmark: LatencyBenchmarkRecording {
  let directoryURL = URL(fileURLWithPath: "/dev/null")
  var isRecording: Bool { terminal == nil }
  let events: EvalEvents
  private var origin = 0.0
  private(set) var milestones: [String: Double] = [:]
  private(set) var terminal: BenchmarkTerminalResult?
  private(set) var failure: [String: Any] = [:]
  private(set) var fallback = false
  private(set) var capturedBytes = 0
  private(set) var sentBytes = 0
  private(set) var maxBufferedBytes = 0

  init(events: EvalEvents) { self.events = events }
  func begin(enabled: Bool, transcriptionConfiguration: TranscriptionConfiguration,
             cleanupMode: CleanupMode, cleanupConfiguration: CleanupConfiguration) {
    origin = events.elapsedMS
    milestones = [:]; terminal = nil; failure = [:]; fallback = false
    capturedBytes = 0; sentBytes = 0; maxBufferedBytes = 0
  }
  func mark(_ milestone: BenchmarkMilestone) {
    guard milestones[milestone.rawValue] == nil else { return }
    let now = events.elapsedMS
    milestones[milestone.rawValue] = now - origin
    events.emit("milestone", ["name": milestone.rawValue, "session_ms": now - origin], at: now)
  }
  func recordAudioCaptured(bytes: Int, bufferedBytes: Int) {
    if capturedBytes == 0 { mark(.firstAudioCaptured) }
    capturedBytes += bytes
    maxBufferedBytes = max(maxBufferedBytes, bufferedBytes)
  }
  func recordAudioSent(bytes: Int) {
    if sentBytes == 0 { mark(.firstAudioSent) }
    sentBytes += bytes
  }
  func recordSTTUpdate(_ update: STTBenchmarkUpdate) {
    mark(.firstSTTResponse)
    if update.hasTranscript { mark(.firstTranscript) }
    if update.hasFinalText { mark(.firstFinalTranscript) }
  }
  func recordRawCharacters(_ count: Int) {}
  func recordCleanupMode(_ mode: CleanupMode) {}
  func recordCleanup(_ metrics: CleanupRequestMetrics) {}
  func recordCleanupFallback(rawCharacters: Int, error: Error) { fallback = true }
  func recordCleanedCharacters(_ count: Int) {}
  func finish(_ result: BenchmarkTerminalResult, stage: BenchmarkFailureStage?,
              category: BenchmarkFailureCategory?, httpStatus: Int?) {
    guard terminal == nil else { return }
    mark(.terminal)
    terminal = result
    failure["stage"] = stage?.rawValue
    failure["category"] = category?.rawValue
    failure["http_status"] = httpStatus
  }
  func clearCompletedHistory() {}
  var durations: Any { EvalEvents.object(LatencyBenchmarkRecorder.makeDurationsForStore(from: milestones)) }
}

@MainActor
final class EvalLifecycle: DictationLifecycleObserving {
  let events: EvalEvents
  private(set) var work: [UUID: String] = [:]
  private var sessions: [UUID: Int] = [:]
  init(events: EvalEvents) { self.events = events }
  func workStarted(id: UUID, kind: String) {
    work[id] = kind
    sessions[id] = events.session
    events.emit("work_started", ["id": id.uuidString, "kind": kind])
  }
  func workFinished(id: UUID) {
    let kind = work.removeValue(forKey: id) ?? "unknown"
    let session = sessions.removeValue(forKey: id)
    events.emit("work_finished", ["id": id.uuidString, "kind": kind], session: session)
  }
}

struct EvalReadiness: DictationReadinessChecking {
  func requestMicrophone() async -> Bool { true }
  func accessibilityReady(prompt: Bool) -> Bool { true }
}

struct EvalNotifications: DictationNotificationPosting {
  let events: EvalEvents
  func postReadinessError(_ error: Error) { events.emit("notification_suppressed", ["category": evalFailure(error)]) }
}

struct EvalLoginItems: LoginItemManaging {
  var status: LoginItemStatus { .disabled }
  func setEnabled(_ enabled: Bool) throws {}
}

final class EvalMuter: OutputMuting {
  func mute() -> Bool { true }
  func restore() {}
}

@MainActor
final class EvalCues: SoundCuePlaying {
  let startCaptureDelay: Duration = .milliseconds(300)
  func play(_ cue: DictationCue) {}
}

@MainActor
final class EvalNotch: NotchPresenting {
  func present(state: NotchState) {}
  func hide(after delay: Duration) {}
}

@MainActor
final class EvalReceiver: TextInserting {
  let events: EvalEvents
  private(set) var output: String?
  init(events: EvalEvents) { self.events = events }
  func reset() { output = nil }
  func captureTarget() -> Task<TextInsertionTarget?, Never> { Task { nil } }
  func insert(_ text: String, into target: TextInsertionTarget?) async -> InsertionResult {
    output = text
    events.emit("output", ["text": text, "destination": "controlled_receiver"])
    return .pasteSent
  }
}

/// STT-only runs preserve coordinator stop/drain/finalization ordering but bypass cleanup requests.
struct EvalIdentityCleaner: CleaningText {
  func clean(_ text: String, instructions: CleanupInstructions, configuration: CleanupConfiguration, apiKey: String) async throws -> CleanupTextResult {
    CleanupTextResult(text: text, metrics: CleanupRequestMetrics(
      actualModel: nil, selectedProvider: nil, selectedProviderModel: nil, routingStrategy: nil,
      routingAttempt: nil, serviceTier: nil, promptTokens: nil, completionTokens: nil,
      totalTokens: nil, httpStatus: nil))
  }
}

func evalPhase(_ phase: DictationPhase) -> String {
  switch phase {
  case .idle: "idle"
  case .starting: "starting"
  case .recording: "recording"
  case .processing: "processing"
  case .cleaning: "cleaning"
  case .inserting: "inserting"
  case .success: "success"
  case .error: "error"
  }
}

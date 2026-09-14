import Foundation

/// Deterministic harness client; real inference uses LocalRealtimeClient.
@MainActor
final class EvalControlledLocalClient: RealtimeTranscribing {
  var onTranscript: ((RealtimeTranscriptUpdate) -> Void)?
  var onError: ((Error) -> Void)?
  private let text: String
  private let script: ControlledResponses
  private var generation = UUID()
  private var active = false
  private var pendingDelay: Task<Void, Error>?

  init(text: String, script: ControlledResponses) {
    self.text = text
    self.script = script
  }

  func connect(configuration: TranscriptionConfiguration, apiKey: String,
               vocabulary: [String], sessionID: DictationSessionID) async throws {
    cancel()
    let current = generation
    try await delay(script.connectDelayMs, generation: current)
    if script.fault == "connection" { throw URLError(.cannotConnectToHost) }
    active = true
  }

  func send(_ frame: RealtimeAudioFrame) async throws {
    try Task.checkCancellation()
    guard active else { throw CancellationError() }
    onTranscript?(RealtimeTranscriptUpdate(snapshot: TranscriptSnapshot(provisional: text),
      hasFinalText: false, finalAudioProcessedMS: nil, totalAudioProcessedMS: nil))
  }

  func finish() async throws -> String {
    guard active else { throw CancellationError() }
    let current = generation
    defer { if generation == current { active = false } }
    try await delay(script.finalizeDelayMs, generation: current)
    if script.fault == "finalize_timeout" { throw AppError.finalizeTimeout }
    return text
  }

  func cancel() {
    generation = UUID()
    active = false
    pendingDelay?.cancel()
    pendingDelay = nil
  }

  private func delay(_ milliseconds: Double?, generation current: UUID) async throws {
    let task = Task { try await Task.sleep(for: .milliseconds(milliseconds ?? 0)) }
    pendingDelay = task
    defer { if generation == current { pendingDelay = nil } }
    try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      task.cancel()
    }
    try Task.checkCancellation()
    guard generation == current else { throw CancellationError() }
  }
}

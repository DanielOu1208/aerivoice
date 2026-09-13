import Foundation

/// Deterministic harness transport; real inference uses LocalRealtimeClient.
@MainActor
final class EvalControlledLocalClient: RealtimeTranscribing {
  var onTranscript: ((RealtimeTranscriptUpdate) -> Void)?
  var onError: ((Error) -> Void)?
  private let text: String
  private var active = false
  init(text: String) { self.text = text }
  func connect(configuration: TranscriptionConfiguration, apiKey: String,
               vocabulary: [String], sessionID: DictationSessionID) async throws { active = true }
  func send(_ frame: RealtimeAudioFrame) async throws {
    guard active else { throw CancellationError() }
    onTranscript?(RealtimeTranscriptUpdate(snapshot: TranscriptSnapshot(provisional: text),
      hasFinalText: false, finalAudioProcessedMS: nil, totalAudioProcessedMS: nil))
  }
  func finish() async throws -> String {
    guard active else { throw CancellationError() }
    active = false
    return text
  }
  func cancel() { active = false }
}

import Foundation

/// A task chain prevents actor reentrancy from resetting a decoder during inference.
/// Cancelling a recording invalidates its results immediately, then drains before reset.
@MainActor
final class LocalSpeechRuntime {
  private var manager: (any LocalSpeechEngine)?
  private let makeEngine: () -> any LocalSpeechEngine

  init(makeEngine: @escaping () -> any LocalSpeechEngine = { FluidLocalSpeechEngine() }) {
    self.makeEngine = makeEngine
  }
  private var tail: Task<Void, Never>?
  private var session: UUID?
  private var releaseRequested = false
  private(set) var isReady = false
  var hasActiveSession: Bool { session != nil }

  private func serialized<T: Sendable>(
    _ operation: @escaping @MainActor () async throws -> T
  ) async throws -> T {
    let previous = tail
    let task = Task { @MainActor in
      await previous?.value
      return try await operation()
    }
    tail = Task { _ = try? await task.value }
    return try await task.value
  }

  func load(from directory: URL) async throws {
    try await serialized { [self] in
      guard manager == nil else { releaseRequested = false; isReady = true; return }
      let model = makeEngine()
      try await model.load(from: directory)
      manager = model
      releaseRequested = false
      isReady = true
    }
  }

  func begin(_ id: UUID, vocabulary: [String]) async throws {
    session = id
    try await serialized { [self] in
      guard session == id, let manager, isReady else { throw CancellationError() }
      await manager.reset()
      await manager.setVocabulary(vocabulary)
    }
  }

  func process(_ samples: [Float], id: UUID) async throws -> String {
    try await serialized { [self] in
      guard session == id, let manager else { throw CancellationError() }
      let text = try await manager.process(samples)
      guard session == id else { throw CancellationError() }
      return text
    }
  }

  func finish(_ id: UUID) async throws -> String {
    try await serialized { [self] in
      guard session == id, let manager else { throw CancellationError() }
      let text = try await manager.finish()
      guard session == id else { throw CancellationError() }
      session = nil
      if releaseRequested { self.manager = nil }
      return text
    }
  }

  func cancel(_ id: UUID) {
    guard session == id else { return }
    session = nil
    // Append synchronously: a subsequent begin must wait for this reset.
    let previous = tail
    tail = Task { @MainActor [self] in
      await previous?.value
      await manager?.reset()
      if releaseRequested, session == nil { manager = nil }
    }
  }

  func unload() async {
    releaseRequested = true
    isReady = false
    _ = try? await serialized { [self] in
      if session == nil { manager = nil }
    }
  }
}

@MainActor
final class LocalRealtimeClient: RealtimeTranscribing {
  var onTranscript: ((RealtimeTranscriptUpdate) -> Void)?
  var onError: ((Error) -> Void)?
  private let runtime: LocalSpeechRuntime
  private var generation: UUID?
  private var lastPartial = ""

  init(runtime: LocalSpeechRuntime = LocalModelController.shared.runtime) {
    self.runtime = runtime
  }

  func connect(configuration: TranscriptionConfiguration, apiKey: String,
               vocabulary: [String], sessionID: DictationSessionID) async throws {
    cancel()
    let id = UUID()
    generation = id
    lastPartial = ""
    try await runtime.begin(id, vocabulary: vocabulary)
    guard generation == id, !Task.isCancelled else { throw CancellationError() }
  }

  static func samples(from data: Data) throws -> [Float] {
    guard data.count.isMultiple(of: 2) else {
      throw AppError.provider("Local transcription received incomplete audio samples.")
    }
    return data.withUnsafeBytes { bytes in
      stride(from: 0, to: bytes.count, by: 2).map { offset in
        Float(Int16(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: Int16.self))) / 32768
      }
    }
  }

  func send(_ frame: RealtimeAudioFrame) async throws {
    guard let id = generation else { throw CancellationError() }
    let text = try await runtime.process(Self.samples(from: frame.audio), id: id)
    guard generation == id, !Task.isCancelled else { throw CancellationError() }
    guard !text.isEmpty, text != lastPartial else { return }
    lastPartial = text
    onTranscript?(RealtimeTranscriptUpdate(snapshot: TranscriptSnapshot(provisional: text),
      hasFinalText: false, finalAudioProcessedMS: nil, totalAudioProcessedMS: nil))
  }

  func finish() async throws -> String {
    guard let id = generation else { throw CancellationError() }
    let text = try await runtime.finish(id)
    guard generation == id, !Task.isCancelled else { throw CancellationError() }
    generation = nil
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw AppError.emptyTranscript
    }
    onTranscript?(RealtimeTranscriptUpdate(snapshot: TranscriptSnapshot(confirmed: text),
      hasFinalText: true, finalAudioProcessedMS: nil, totalAudioProcessedMS: nil))
    return text
  }

  func cancel() {
    guard let id = generation else { return }
    generation = nil
    runtime.cancel(id)
  }
}

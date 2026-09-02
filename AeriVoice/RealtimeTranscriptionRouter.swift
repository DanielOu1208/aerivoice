import Foundation

@MainActor
final class RealtimeTranscriptionRouter: RealtimeTranscribing {
  var onTranscript: ((RealtimeTranscriptUpdate) -> Void)?
  var onError: ((Error) -> Void)?

  private let soniox: RealtimeTranscribing
  private let meta: RealtimeTranscribing
  private var activeProvider: TranscriptionProvider?
  private var connectionGeneration = UUID()

  init(
    soniox: RealtimeTranscribing = SonioxRealtimeClient(),
    meta: RealtimeTranscribing = MetaRealtimeClient()
  ) {
    self.soniox = soniox
    self.meta = meta
    wire(soniox, provider: .soniox)
    wire(meta, provider: .meta)
  }

  func connect(
    configuration: TranscriptionConfiguration, apiKey: String, vocabulary: [String],
    sessionID: DictationSessionID
  ) async throws {
    cancel()
    let generation = UUID()
    connectionGeneration = generation
    activeProvider = configuration.provider
    do {
      try await client(for: configuration.provider).connect(
        configuration: configuration, apiKey: apiKey, vocabulary: vocabulary,
        sessionID: sessionID)
    } catch {
      if connectionGeneration == generation { activeProvider = nil }
      throw error
    }
  }

  func send(_ frame: RealtimeAudioFrame) async throws {
    guard let activeProvider else {
      throw AppError.provider("The transcription provider is not connected.")
    }
    try await client(for: activeProvider).send(frame)
  }

  func finish() async throws -> String {
    guard let activeProvider else {
      throw AppError.provider("The transcription provider is not connected.")
    }
    return try await client(for: activeProvider).finish()
  }

  func cancel() {
    connectionGeneration = UUID()
    activeProvider = nil
    soniox.cancel()
    meta.cancel()
  }

  private func wire(_ client: RealtimeTranscribing, provider: TranscriptionProvider) {
    client.onTranscript = { [weak self] update in
      guard self?.activeProvider == provider else { return }
      self?.onTranscript?(update)
    }
    client.onError = { [weak self] error in
      guard self?.activeProvider == provider else { return }
      self?.onError?(error)
    }
  }

  private func client(for provider: TranscriptionProvider) -> RealtimeTranscribing {
    switch provider {
    case .soniox: soniox
    case .meta: meta
    }
  }
}

enum RealtimeTranscriptionPrewarmer {
  nonisolated static func prewarm(provider: TranscriptionProvider? = nil) {
    Task.detached(priority: .utility) {
      let urls: [URL]
      switch provider {
      case .meta:
        urls = [URL(string: "https://api.meta.ai")].compactMap { $0 }
      case .soniox:
        urls = [URL(string: "https://stt-rt.soniox.com")].compactMap { $0 }
      case nil:
        urls = [
          URL(string: "https://api.meta.ai"),
          URL(string: "https://stt-rt.soniox.com"),
        ].compactMap { $0 }
      }
      for url in urls {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 3
        _ = try? await URLSession.shared.data(for: request)
      }
    }
  }
}


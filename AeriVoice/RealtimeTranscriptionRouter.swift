import Foundation

@MainActor
final class RealtimeTranscriptionRouter: RealtimeTranscribing {
  var onTranscript: ((RealtimeTranscriptUpdate) -> Void)?
  var onError: ((Error) -> Void)?
  var onAudioSent: ((Int) -> Void)?
  var onConnectionEvent: ((String) -> Void)?
  var reportsAudioSends: Bool {
    activeProvider.map { client(for: $0).reportsAudioSends } ?? false
  }
  var hasPreparedConnection: Bool { grok.hasPreparedConnection }

  private let soniox: RealtimeTranscribing
  private let meta: RealtimeTranscribing
  private let grok: RealtimeTranscribing
  private let local: RealtimeTranscribing
  private let apple: RealtimeTranscribing
  private var activeLocalModel: LocalTranscriptionModel = .nemotron
  private var activeProvider: TranscriptionProvider?
  private var connectionGeneration = UUID()

  init(
    soniox: RealtimeTranscribing = SonioxRealtimeClient(),
    meta: RealtimeTranscribing = MetaRealtimeClient(),
    grok: RealtimeTranscribing = GrokRealtimeClient(),
    local: RealtimeTranscribing = LocalRealtimeClient(),
    apple: RealtimeTranscribing = AppleRealtimeClient()
  ) {
    self.soniox = soniox
    self.meta = meta
    self.grok = grok
    self.local = local
    self.apple = apple
    wire(local, provider: .local, localModel: .nemotron)
    wire(apple, provider: .local, localModel: .apple)
    wire(soniox, provider: .soniox)
    wire(meta, provider: .meta)
    wire(grok, provider: .grok)
  }

  func connect(
    configuration: TranscriptionConfiguration, apiKey: String, vocabulary: [String],
    sessionID: DictationSessionID
  ) async throws {
    // A ready, unused Grok session belongs to preparation until connect adopts it.
    // Ordinary cancellation still disposes of both active and prepared work.
    cancelActiveConnection()
    if configuration.provider != .grok { invalidatePreparedConnection() }
    let generation = UUID()
    connectionGeneration = generation
    activeProvider = configuration.provider
    activeLocalModel = configuration.localModel
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
    let generation = connectionGeneration
    defer { if connectionGeneration == generation { self.activeProvider = nil } }
    return try await client(for: activeProvider).finish()
  }

  func flushAudio() async throws {
    guard let activeProvider else { throw CancellationError() }
    try await client(for: activeProvider).flushAudio()
  }

  func prepareConnection(
    configuration: TranscriptionConfiguration, apiKey: String, vocabulary: [String]
  ) async -> Bool {
    guard activeProvider == nil, configuration.provider == .grok else { return false }
    return await grok.prepareConnection(configuration: configuration, apiKey: apiKey, vocabulary: vocabulary)
  }

  func invalidatePreparedConnection() { grok.invalidatePreparedConnection() }

  func cancelActiveConnection() {
    connectionGeneration = UUID()
    activeProvider = nil
    soniox.cancelActiveConnection()
    meta.cancelActiveConnection()
    grok.cancelActiveConnection()
    local.cancelActiveConnection()
    apple.cancelActiveConnection()
  }

  func cancel() {
    connectionGeneration = UUID()
    activeProvider = nil
    soniox.cancel()
    meta.cancel()
    grok.cancel()
    local.cancel()
    apple.cancel()
  }

  private func wire(_ client: RealtimeTranscribing, provider: TranscriptionProvider, localModel: LocalTranscriptionModel? = nil) {
    client.onAudioSent = { [weak self] count in
      guard self?.activeProvider == provider else { return }
      self?.onAudioSent?(count)
    }
    client.onConnectionEvent = { [weak self] event in self?.onConnectionEvent?(event) }
    client.onTranscript = { [weak self] update in
      guard self?.activeProvider == provider, localModel == nil || self?.activeLocalModel == localModel else { return }
      self?.onTranscript?(update)
    }
    client.onError = { [weak self] error in
      guard self?.activeProvider == provider, localModel == nil || self?.activeLocalModel == localModel else { return }
      self?.onError?(error)
    }
  }

  private func client(for provider: TranscriptionProvider) -> RealtimeTranscribing {
    switch provider {
    case .soniox: soniox
    case .meta: meta
    case .grok: grok
    case .local: activeLocalModel == .apple ? apple : local
    }
  }
}

enum RealtimeTranscriptionPrewarmer {
  nonisolated static func prewarm(
    provider: TranscriptionProvider? = nil, completion: (@Sendable (Bool) -> Void)? = nil
  ) {
    Task.detached(priority: .utility) {
      var succeeded = true
      let urls: [URL]
      switch provider {
      case .local:
        urls = []
      case .grok:
        urls = [URL(string: "https://api.x.ai")].compactMap { $0 }
      case .meta:
        urls = [URL(string: "https://api.meta.ai")].compactMap { $0 }
      case .soniox:
        urls = [URL(string: "https://stt-rt.soniox.com")].compactMap { $0 }
      case nil:
        urls = [
          URL(string: "https://api.meta.ai"),
          URL(string: "https://api.x.ai"),
          URL(string: "https://stt-rt.soniox.com"),
        ].compactMap { $0 }
      }
      for url in urls {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 3
        if (try? await AppNetworkPolicy.shared.data(for: request)) == nil { succeeded = false }
      }
      completion?(succeeded)
    }
  }
}

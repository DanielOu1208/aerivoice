import Foundation

extension TranscriptionProvider {
  /// A client that has not been used yet. The router keeps one per provider; checking a key
  /// uses its own.
  @MainActor
  func makeClient() -> RealtimeTranscribing {
    switch self {
    case .soniox: SonioxRealtimeClient()
    case .meta: MetaRealtimeClient()
    case .grok: GrokRealtimeClient()
    case .cartesia: CartesiaRealtimeClient()
    case .local: LocalRealtimeClient()
    }
  }
}

@MainActor
final class RealtimeTranscriptionRouter: RealtimeTranscribing {
  var onTranscript: ((RealtimeTranscriptUpdate) -> Void)?
  var onError: ((Error) -> Void)?
  var onAudioSent: ((Int) -> Void)?
  var onConnectionEvent: ((String) -> Void)?
  var reportsAudioSends: Bool {
    activeProvider.map { client(for: $0).reportsAudioSends } ?? false
  }
  var hasPreparedConnection: Bool { clients.values.contains { $0.hasPreparedConnection } }

  private let clients: [TranscriptionProvider: RealtimeTranscribing]
  /// Local's other engine; `clients[.local]` is Nemotron.
  private let apple: RealtimeTranscribing
  private var activeLocalModel: LocalTranscriptionModel = .nemotron
  private var activeProvider: TranscriptionProvider?
  private var connectionGeneration = UUID()

  /// `clients` replaces the usual client of each provider it names.
  init(
    clients replacements: [TranscriptionProvider: RealtimeTranscribing] = [:],
    apple: RealtimeTranscribing = AppleRealtimeClient()
  ) {
    var clients: [TranscriptionProvider: RealtimeTranscribing] = [:]
    for provider in TranscriptionProvider.allCases {
      clients[provider] = replacements[provider] ?? provider.makeClient()
    }
    self.clients = clients
    self.apple = apple
    for (provider, client) in clients {
      wire(client, provider: provider, localModel: provider == .local ? .nemotron : nil)
    }
    wire(apple, provider: .local, localModel: .apple)
  }

  func connect(
    configuration: TranscriptionConfiguration, apiKey: String, vocabulary: [String],
    sessionID: DictationSessionID
  ) async throws {
    // A ready, unused session of this provider belongs to preparation until connect adopts
    // it. Ordinary cancellation still disposes of both active and prepared work.
    cancelActiveConnection()
    for (provider, client) in clients where provider != configuration.provider {
      client.invalidatePreparedConnection()
    }
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

  /// False for a provider whose client cannot prepare a connection ahead of time.
  func prepareConnection(
    configuration: TranscriptionConfiguration, apiKey: String, vocabulary: [String]
  ) async -> Bool {
    guard activeProvider == nil, let client = clients[configuration.provider] else { return false }
    return await client.prepareConnection(
      configuration: configuration, apiKey: apiKey, vocabulary: vocabulary)
  }

  func invalidatePreparedConnection() {
    clients.values.forEach { $0.invalidatePreparedConnection() }
  }

  func cancelActiveConnection() {
    connectionGeneration = UUID()
    activeProvider = nil
    clients.values.forEach { $0.cancelActiveConnection() }
    apple.cancelActiveConnection()
  }

  func cancel() {
    connectionGeneration = UUID()
    activeProvider = nil
    clients.values.forEach { $0.cancel() }
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
    if provider == .local, activeLocalModel == .apple { return apple }
    guard let client = clients[provider] else {
      preconditionFailure("The router is built with a client for every provider.")
    }
    return client
  }
}

enum RealtimeTranscriptionPrewarmer {
  /// Contacts the provider's host so the next connection opens faster. No key, audio or
  /// dictionary term is sent. Succeeds at once for a provider with nothing to contact.
  nonisolated static func prewarm(
    provider: TranscriptionProvider, completion: (@Sendable (Bool) -> Void)? = nil
  ) {
    Task.detached(priority: .utility) {
      guard let host = provider.descriptor.prewarmHost, let url = URL(string: "https://\(host)")
      else {
        completion?(true)
        return
      }
      var request = URLRequest(url: url)
      request.httpMethod = "HEAD"
      request.timeoutInterval = 3
      completion?((try? await AppNetworkPolicy.shared.data(for: request)) != nil)
    }
  }
}

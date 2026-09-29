import Foundation

@MainActor
protocol GrokWebSocketTransport: AnyObject {
  func resume()
  func send(_ message: URLSessionWebSocketTask.Message) async throws
  func receive() async throws -> URLSessionWebSocketTask.Message
  func ping() async throws
  func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?)
}

@MainActor
private final class URLSessionGrokTransport: GrokWebSocketTransport {
  private let session: URLSession
  private let task: URLSessionWebSocketTask

  init(request: URLRequest) {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 3
    session = URLSession(configuration: configuration)
    task = session.webSocketTask(with: request)
  }

  func resume() { AppNetworkPolicy.shared.resume(task) }
  func send(_ message: URLSessionWebSocketTask.Message) async throws {
    do { try await task.send(message) } catch { throw sanitizedError() }
  }
  func receive() async throws -> URLSessionWebSocketTask.Message {
    do { return try await task.receive() } catch { throw sanitizedError() }
  }
  func ping() async throws {
    let task = self.task
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      task.sendPing { error in
        if error != nil { continuation.resume(throwing: GrokTransportError(status: nil)) }
        else { continuation.resume() }
      }
    }
  }
  func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
    AppNetworkPolicy.shared.forget(task)
    task.cancel(with: closeCode, reason: nil)
    session.invalidateAndCancel()
  }
  private func sanitizedError() -> GrokTransportError {
    let status = (task.response as? HTTPURLResponse)?.statusCode
    return GrokTransportError(status: status == 101 ? task.closeCode.rawValue : status)
  }
}

@MainActor
final class GrokRealtimeClient: RealtimeTranscribing {
  var onTranscript: ((RealtimeTranscriptUpdate) -> Void)?
  var onError: ((Error) -> Void)?
  var onAudioSent: ((Int) -> Void)?
  var onConnectionEvent: ((String) -> Void)?
  var reportsAudioSends: Bool { true }

  private let packetPolicy: GrokAudioPacketPolicy
  private let clock: GrokRealtimeClock
  private let makeTransport: (URLRequest) -> any GrokWebSocketTransport
  private let connectionTimeout: Duration
  private let finalizationTimeout: Duration
  private let preparedLifetime: Duration
  private var active: GrokRealtimeSession?
  private var prepared: Prepared?
  private var preparationExpiry: Task<Void, Never>?

  private final class Prepared {
    let session: GrokRealtimeSession
    let key: String
    let model: String
    let vocabulary: [String]
    var readyAt: ContinuousClock.Instant?
    init(session: GrokRealtimeSession, key: String, model: String, vocabulary: [String]) {
      self.session = session
      self.key = key
      self.model = model
      self.vocabulary = vocabulary
    }
  }

  /// Idle sockets are not billed (xAI bills per audio second). Live probes kept idle sessions
  /// open for 10 minutes; replacing them sooner stays well inside that.
  static let preparedLifetime: Duration = .seconds(300)
  /// A socket idle this long is pinged before adoption, catching sleep or network changes.
  static let adoptionPingThreshold: Duration = .seconds(15)
  static let adoptionPingTimeout: Duration = .seconds(1)

  var hasPreparedConnection: Bool {
    guard let prepared else { return false }
    guard let readyAt = prepared.readyAt else { return false }
    return clock.now() < readyAt.advanced(by: preparedLifetime)
  }

  init(
    connectionTimeout: Duration = .seconds(3), finalizationTimeout: Duration = .seconds(3),
    preparedLifetime: Duration = GrokRealtimeClient.preparedLifetime,
    packetPolicy: GrokAudioPacketPolicy = .captureFrames,
    clock: GrokRealtimeClock = .continuous,
    makeTransport: @escaping (URLRequest) -> any GrokWebSocketTransport = { URLSessionGrokTransport(request: $0) }
  ) {
    self.packetPolicy = packetPolicy
    self.clock = clock
    self.connectionTimeout = connectionTimeout
    self.finalizationTimeout = finalizationTimeout
    self.preparedLifetime = preparedLifetime
    self.makeTransport = makeTransport
  }

  func connect(configuration: TranscriptionConfiguration, apiKey: String, vocabulary: [String],
               sessionID: DictationSessionID) async throws {
    cancelActiveConnection()
    try Task.checkCancellation()
    try AppNetworkPolicy.shared.checkAllowed()
    guard configuration.provider == .grok else {
      throw AppError.provider("The selected transcription model is not available through Grok.")
    }
    if let slot = prepared, let readyAt = slot.readyAt,
       clock.now() < readyAt.advanced(by: preparedLifetime),
       slot.key == apiKey, slot.model == configuration.modelID,
       slot.vocabulary == GrokVocabulary(vocabulary).terms,
       await isAlive(slot, readyAt: readyAt) {
      try Task.checkCancellation()
      prepared = nil
      preparationExpiry?.cancel()
      preparationExpiry = nil
      active = slot.session
      installCallbacks(on: slot.session)
      onConnectionEvent?("preparationHit")
      return
    }
    invalidatePreparedConnection()
    onConnectionEvent?("preparationMiss")
    let session = makeSession()
    active = session
    installCallbacks(on: session)
    do {
      try await session.connect(apiKey: apiKey, vocabulary: vocabulary)
    } catch {
      if active === session { active = nil }
      throw error
    }
  }

  func send(_ frame: RealtimeAudioFrame) async throws {
    try Task.checkCancellation()
    guard let active else { throw AppError.provider("Grok is not accepting audio.") }
    try await active.send(frame)
  }

  func flushAudio() async throws {
    try Task.checkCancellation()
    try await active?.flushAudio()
  }

  func finish() async throws -> String {
    try Task.checkCancellation()
    guard let session = active else {
      throw AppError.provider("Grok is not ready to finish this transcription.")
    }
    defer { if session.isTerminated, active === session { active = nil } }
    return try await session.finish()
  }

  func cancel() {
    cancelActiveConnection()
    invalidatePreparedConnection()
  }

  func cancelActiveConnection() {
    let session = active
    active = nil
    session?.cancel()
  }

  func invalidatePreparedConnection() {
    guard let slot = prepared else { return }
    prepared = nil
    preparationExpiry?.cancel()
    preparationExpiry = nil
    slot.session.cancel()
    onConnectionEvent?("preparationInvalidated")
  }

  func prepareConnection(configuration: TranscriptionConfiguration, apiKey: String,
                         vocabulary: [String]) async -> Bool {
    guard active == nil, configuration.provider == .grok else { return false }
    let terms = GrokVocabulary(vocabulary).terms
    if let slot = prepared, slot.key == apiKey, slot.model == configuration.modelID,
       slot.vocabulary == terms {
      guard let readyAt = slot.readyAt else { return false }
      if clock.now() < readyAt.advanced(by: preparedLifetime) { return true }
    }
    invalidatePreparedConnection()
    let session = makeSession()
    let slot = Prepared(session: session, key: apiKey, model: configuration.modelID,
      vocabulary: terms)
    prepared = slot
    session.onError = { [weak self, weak slot] _ in
      guard let self, let slot, self.prepared === slot else { return }
      self.discard(slot, event: "preparationFailed")
    }
    session.onTranscript = { [weak self, weak slot] _ in
      guard let self, let slot, self.prepared === slot else { return }
      self.discard(slot, event: "preparationFailed")
    }
    onConnectionEvent?("preparationStarted")
    do {
      try await session.connect(apiKey: apiKey, vocabulary: terms)
      guard prepared === slot else { return false }
      let readyAt = clock.now()
      slot.readyAt = readyAt
      preparationExpiry = Task { [weak self, weak slot, clock, preparedLifetime] in
        do { try await clock.sleep(readyAt.advanced(by: preparedLifetime)) } catch { return }
        guard !Task.isCancelled, let self, let slot, self.prepared === slot else { return }
        self.discard(slot, event: "preparationExpired")
      }
      onConnectionEvent?("preparationReady")
      return true
    } catch {
      if prepared === slot { discard(slot, event: "preparationFailed") }
      return false
    }
  }

  /// A long-idle socket can be dead without a close event (sleep, network change).
  private func isAlive(_ slot: Prepared, readyAt: ContinuousClock.Instant) async -> Bool {
    guard clock.now() >= readyAt.advanced(by: Self.adoptionPingThreshold) else { return true }
    let alive = await slot.session.ping(timeout: Self.adoptionPingTimeout)
    if !alive { discard(slot, event: "preparationStale") }
    return alive && prepared === slot
  }

  private func discard(_ slot: Prepared, event: String) {
    guard prepared === slot else { return }
    prepared = nil
    preparationExpiry?.cancel()
    preparationExpiry = nil
    slot.session.cancel()
    onConnectionEvent?(event)
  }

  private func installCallbacks(on session: GrokRealtimeSession) {
    session.onTranscript = { [weak self, weak session] update in
      guard let self, let session, self.active === session else { return }
      self.onTranscript?(update)
    }
    session.onAudioSent = { [weak self, weak session] count in
      guard let self, let session, self.active === session else { return }
      self.onAudioSent?(count)
    }
    session.onConnectionEvent = { [weak self, weak session] event in
      guard let self, let session, self.active === session else { return }
      self.onConnectionEvent?(event)
    }
    session.onError = { [weak self, weak session] error in
      guard let self, let session, self.active === session else { return }
      self.active = nil
      self.onError?(error)
    }
  }

  private func makeSession() -> GrokRealtimeSession {
    GrokRealtimeSession(connectionTimeout: connectionTimeout,
      finalizationTimeout: finalizationTimeout, packetPolicy: packetPolicy,
      clock: clock, makeTransport: makeTransport)
  }
}

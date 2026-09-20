import Foundation

@MainActor
protocol GrokWebSocketTransport: AnyObject {
  func resume()
  func send(_ message: URLSessionWebSocketTask.Message) async throws
  func receive() async throws -> URLSessionWebSocketTask.Message
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
  private var bufferedAudio = Data()
  private var activeChild: GrokRealtimeClient?
  private var prepared: Prepared?
  private var preparationExpiry: Task<Void, Never>?

  private final class Prepared {
    let client: GrokRealtimeClient
    let key: String
    let model: String
    let vocabulary: [String]
    var readyAt: ContinuousClock.Instant?
    var ready: Bool { readyAt != nil }
    init(client: GrokRealtimeClient, key: String, model: String, vocabulary: [String]) {
      self.client = client
      self.key = key
      self.model = model
      self.vocabulary = vocabulary
    }
  }

  var hasPreparedConnection: Bool {
    guard let prepared else { return false }
    guard let readyAt = prepared.readyAt else { return false }
    return clock.now() < readyAt.advanced(by: .seconds(30))
  }

  private let makeTransport: (URLRequest) -> any GrokWebSocketTransport
  private let connectionTimeout: Duration
  private let finalizationTimeout: Duration
  private var transport: (any GrokWebSocketTransport)?
  private var receiver: Task<Void, Never>?
  private var timeout: Task<Void, Never>?
  private var readyContinuation: CheckedContinuation<Void, Error>?
  private var finishContinuation: CheckedContinuation<String, Error>?
  private var generation = UUID()
  private var ready = false
  private var finishing = false
  private var assembler = GrokTranscriptAssembler()
  private var nextAudioDeadline: ContinuousClock.Instant?

  init(
    connectionTimeout: Duration = .seconds(3), finalizationTimeout: Duration = .seconds(3),
    packetPolicy: GrokAudioPacketPolicy = .captureFrames,
    clock: GrokRealtimeClock = .continuous,
    makeTransport: @escaping (URLRequest) -> any GrokWebSocketTransport = { URLSessionGrokTransport(request: $0) }
  ) {
    self.packetPolicy = packetPolicy
    self.clock = clock
    self.connectionTimeout = connectionTimeout
    self.finalizationTimeout = finalizationTimeout
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
       clock.now() < readyAt.advanced(by: .seconds(30)),
       slot.key == apiKey, slot.model == configuration.modelID,
       slot.vocabulary == GrokVocabulary(vocabulary).terms {
      prepared = nil
      preparationExpiry?.cancel()
      preparationExpiry = nil
      activeChild = slot.client
      installCallbacks(on: slot.client)
      onConnectionEvent?("preparationHit")
      return
    }
    invalidatePreparedConnection()
    onConnectionEvent?("preparationMiss")
    let id = generation
    let socket = makeTransport(GrokRealtimeRequest.make(apiKey: apiKey, vocabulary: vocabulary))
    transport = socket
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        readyContinuation = continuation
        socket.resume()
        receiver = Task { [weak self] in await self?.receive(socket, generation: id) }
        scheduleTimeout(connectionTimeout, error: AppError.connectionTimeout, generation: id)
      }
      try Task.checkCancellation()
      guard generation == id, ready else { throw CancellationError() }
    } onCancel: {
      Task { @MainActor [weak self] in
        guard self?.generation == id else { return }
        self?.cancel()
      }
    }
  }

  func send(_ frame: RealtimeAudioFrame) async throws {
    if let activeChild { try await activeChild.send(frame); return }
    try Task.checkCancellation()
    guard transport != nil, ready, !finishing else {
      throw AppError.provider("Grok is not accepting audio.")
    }
    guard !frame.audio.isEmpty else { return }
    switch packetPolicy {
    case .captureFrames:
      try await sendPacket(frame.audio, queuedBytesAfterPacket: frame.queuedBytesAfterFrame)
    case .milliseconds100:
      bufferedAudio.append(frame.audio)
      while bufferedAudio.count >= 3_200 {
        let packet = Data(bufferedAudio.prefix(3_200))
        bufferedAudio.removeFirst(3_200)
        try await sendPacket(packet,
          queuedBytesAfterPacket: bufferedAudio.count + frame.queuedBytesAfterFrame)
      }
    }
  }

  func flushAudio() async throws {
    if let activeChild { try await activeChild.flushAudio(); return }
    try Task.checkCancellation()
    guard !bufferedAudio.isEmpty else { return }
    let packet = bufferedAudio
    bufferedAudio.removeAll(keepingCapacity: true)
    try await sendPacket(packet)
  }

  private func sendPacket(_ bytes: Data, queuedBytesAfterPacket: Int = 0) async throws {
    guard let socket = transport, ready else { throw CancellationError() }
    let id = generation
    // Send existing backlog faster without changing PCM samples or sample rate.
    // Once the queue clears, resume real-time pacing, as the Meta client does.
    let speedMultiplier = queuedBytesAfterPacket > 0 ? 1.35 : 1.0
    let interval = Duration.seconds(Double(bytes.count) / (32_000 * speedMultiplier))
    if let deadline = nextAudioDeadline { try await clock.sleep(deadline) }
    try Task.checkCancellation()
    guard generation == id, transport === socket else { throw CancellationError() }
    let now = clock.now()
    // Keep the cumulative timeline through small scheduler delays. After a
    // full packet of lateness, rebase so a stalled sender cannot burst.
    let deadline = nextAudioDeadline ?? now
    let base = now >= deadline.advanced(by: interval) ? now : deadline
    nextAudioDeadline = base.advanced(by: interval)
    do { try await socket.send(.data(bytes)) }
    catch {
      guard generation == id else { throw CancellationError() }
      let safe = Self.safeError(error)
      fail(safe)
      throw safe
    }
    guard generation == id else { throw CancellationError() }
    onAudioSent?(bytes.count)
  }

  func finish() async throws -> String {
    if let child = activeChild {
      defer { if activeChild === child { activeChild = nil } }
      return try await child.finish()
    }
    try Task.checkCancellation()
    guard let socket = transport, ready, !finishing else {
      throw AppError.provider("Grok is not ready to finish this transcription.")
    }
    let id = generation
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        finishing = true
        finishContinuation = continuation
        Task { [weak self] in
          guard self?.generation == id else { return }
          do {
            guard let self else { return }
            try await self.flushAudio()
            guard self.generation == id else { return }
            self.scheduleTimeout(self.finalizationTimeout, error: AppError.finalizeTimeout, generation: id)
            try await socket.send(.string(#"{"type":"audio.done"}"#))
            if self.generation == id { self.onConnectionEvent?("audioDoneSent") }
          }
          catch {
            guard self?.generation == id else { return }
            self?.fail(Self.safeError(error))
          }
        }
      }
    } onCancel: {
      Task { @MainActor [weak self] in
        guard self?.generation == id else { return }
        self?.cancel()
      }
    }
  }

  func cancel() {
    cancelActiveConnection()
    invalidatePreparedConnection()
  }

  func cancelActiveConnection() {
    let child = activeChild
    activeChild = nil
    child?.cancel()
    terminate(.failure(CancellationError()))
  }

  func invalidatePreparedConnection() {
    guard let slot = prepared else { return }
    prepared = nil
    preparationExpiry?.cancel()
    preparationExpiry = nil
    slot.client.cancel()
    onConnectionEvent?("preparationInvalidated")
  }

  func prepareConnection(configuration: TranscriptionConfiguration, apiKey: String,
                         vocabulary: [String]) async -> Bool {
    guard transport == nil, activeChild == nil, configuration.provider == .grok else { return false }
    let terms = GrokVocabulary(vocabulary).terms
    if let slot = prepared, slot.key == apiKey, slot.model == configuration.modelID,
       slot.vocabulary == terms {
      guard let readyAt = slot.readyAt else { return false }
      if clock.now() < readyAt.advanced(by: .seconds(30)) { return true }
    }
    invalidatePreparedConnection()
    let child = GrokRealtimeClient(connectionTimeout: connectionTimeout,
      finalizationTimeout: finalizationTimeout, packetPolicy: packetPolicy,
      clock: clock, makeTransport: makeTransport)
    let slot = Prepared(client: child, key: apiKey, model: configuration.modelID,
      vocabulary: terms)
    prepared = slot
    child.onError = { [weak self, weak slot] _ in
      guard let self, let slot, self.prepared === slot else { return }
      self.discard(slot, event: "preparationFailed")
    }
    child.onTranscript = { [weak self, weak slot] _ in
      guard let self, let slot, self.prepared === slot else { return }
      self.discard(slot, event: "preparationFailed")
    }
    onConnectionEvent?("preparationStarted")
    do {
      try await child.connect(configuration: configuration, apiKey: apiKey,
        vocabulary: terms, sessionID: DictationSessionID())
      guard prepared === slot else { return false }
      let readyAt = clock.now()
      slot.readyAt = readyAt
      preparationExpiry = Task { [weak self, weak slot, clock] in
        do { try await clock.sleep(readyAt.advanced(by: .seconds(30))) } catch { return }
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

  private func discard(_ slot: Prepared, event: String) {
    guard prepared === slot else { return }
    prepared = nil
    preparationExpiry?.cancel()
    preparationExpiry = nil
    slot.client.cancel()
    onConnectionEvent?(event)
  }

  private func installCallbacks(on child: GrokRealtimeClient) {
    child.onTranscript = { [weak self, weak child] update in
      guard let self, let child, self.activeChild === child else { return }
      self.onTranscript?(update)
    }
    child.onAudioSent = { [weak self, weak child] count in
      guard let self, let child, self.activeChild === child else { return }
      self.onAudioSent?(count)
    }
    child.onConnectionEvent = { [weak self, weak child] event in
      guard let self, let child, self.activeChild === child else { return }
      self.onConnectionEvent?(event)
    }
    child.onError = { [weak self, weak child] error in
      guard let self, let child, self.activeChild === child else { return }
      self.activeChild = nil
      self.onError?(error)
    }
  }

  private func receive(_ socket: any GrokWebSocketTransport, generation id: UUID) async {
    do {
      while generation == id && !Task.isCancelled {
        let message = try await socket.receive()
        guard generation == id else { return }
        let data: Data
        switch message {
        case .data(let bytes): data = bytes
        case .string(let string): data = Data(string.utf8)
        @unknown default: continue
        }
        try consume(JSONDecoder().decode(GrokRealtimeResponse.self, from: data))
      }
    } catch {
      guard generation == id else { return }
      fail(Self.safeError(error))
    }
  }

  private func consume(_ response: GrokRealtimeResponse) throws {
    switch response.type {
    case "transcript.created":
      guard let continuation = readyContinuation else { return }
      readyContinuation = nil
      timeout?.cancel()
      timeout = nil
      ready = true
      continuation.resume()
    case "transcript.partial":
      guard ready else { throw AppError.provider("Grok sent text before the session was ready.") }
      let update = try assembler.consume(response)
      onTranscript?(update)
    case "transcript.done":
      guard finishing, let text = response.text else {
        throw AppError.provider("Grok ended the transcription unexpectedly.")
      }
      let sessionText = text.trimmingCharacters(in: .whitespacesAndNewlines)
      // Live xAI sessions can finish with an empty terminal acknowledgement
      // after emitting all text in finalized partial events. Only committed
      // text is eligible here; interim text never recovers a missing final.
      let final = sessionText.isEmpty
        ? assembler.confirmedText.trimmingCharacters(in: .whitespacesAndNewlines)
        : sessionText
      onTranscript?(RealtimeTranscriptUpdate(snapshot: TranscriptSnapshot(confirmed: final),
        hasFinalText: !final.isEmpty, finalAudioProcessedMS: nil, totalAudioProcessedMS: nil))
      terminate(final.isEmpty ? .failure(AppError.emptyTranscript) : .success(final))
    case "error":
      throw AppError.provider("Grok rejected the transcription session. Check your API account and try again.")
    default: break
    }
  }

  private func scheduleTimeout(_ duration: Duration, error: AppError, generation id: UUID) {
    timeout?.cancel()
    timeout = Task { [weak self] in
      do { try await Task.sleep(for: duration) } catch { return }
      guard self?.generation == id else { return }
      self?.fail(error)
    }
  }

  private func fail(_ error: Error) {
    let notify = ready && finishContinuation == nil
    terminate(.failure(error))
    if notify { onError?(error) }
  }

  private func terminate(_ result: Result<String, Error>) {
    generation = UUID()
    timeout?.cancel()
    timeout = nil
    receiver?.cancel()
    receiver = nil
    transport?.cancel(with: .normalClosure, reason: nil)
    transport = nil
    let connection = readyContinuation
    let finish = finishContinuation
    readyContinuation = nil
    finishContinuation = nil
    ready = false
    finishing = false
    assembler = GrokTranscriptAssembler()
    nextAudioDeadline = nil
    bufferedAudio.removeAll(keepingCapacity: true)
    if let connection { connection.resume(throwing: result.failure ?? CancellationError()) }
    finish?.resume(with: result)
  }

  private static func safeError(_ error: Error) -> Error {
    if error is CancellationError { return CancellationError() }
    if error is DecodingError { return AppError.provider("Grok returned an invalid transcript event.") }
    if let error = error as? AppError { return error }
    if let error = error as? GrokTransportError { return error }
    return GrokTransportError(status: nil)
  }
}

private extension Result {
  var failure: Failure? {
    if case .failure(let error) = self { return error }
    return nil
  }
}

import Foundation
import OSLog

/// Cartesia takes at most 100 keyterms totalling 1,200 characters, fixed when the connection
/// opens. Provider limits do not change the user's shared dictionary.
///
/// The terms travel in the request URL, and Cartesia refuses a URL past about 8 KB: live, a
/// 7,612-byte URL connected and an 8,512-byte one got HTTP 414 (2026-10-05). A character
/// outside ASCII takes six to twelve bytes once escaped, so a dictionary in Japanese or Hindi
/// reaches that size well before 1,200 characters, and every dictation would then fail to
/// connect. The escaped size is therefore limited too.
struct CartesiaKeyterms: Equatable {
  static let maximumCount = 100
  static let maximumCharacters = 1_200
  /// For the keyterm part of the URL. The rest of the URL is about 120 bytes.
  static let maximumQueryBytes = 6_800

  let terms: [String]
  let excluded: [String]

  init(_ vocabulary: [String]) {
    var accepted: [String] = []
    var excluded: [String] = []
    var characters = 0
    var queryBytes = 0
    for term in VocabularyNormalizer.parse(vocabulary.joined(separator: "\n")) {
      let length = term.unicodeScalars.count
      let bytes = Self.queryItem(term).utf8.count + 1
      // A term that doesn't fit is skipped, so shorter terms after it can still be sent.
      if accepted.count < Self.maximumCount, characters + length <= Self.maximumCharacters,
        queryBytes + bytes <= Self.maximumQueryBytes
      {
        accepted.append(term)
        characters += length
        queryBytes += bytes
      } else {
        excluded.append(term)
      }
    }
    terms = accepted
    self.excluded = excluded
  }

  /// One term as it appears in the URL. URLQueryItem leaves "+" and "&" readable, which
  /// would change terms such as "C++".
  static func queryItem(_ term: String) -> String {
    "keyterm=" + (term.addingPercentEncoding(withAllowedCharacters: unreserved) ?? "")
  }

  private static let unreserved = CharacterSet(
    charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
}

enum CartesiaRealtimeRequest {
  /// The API version this integration was written against.
  static let apiVersion = "2026-08-14"

  /// The manual-finalize endpoint: the client says when the speaker is done.
  static func make(apiKey: String, model: String, vocabulary: [String]) -> URLRequest {
    let items =
      [
        "model=\(model)", "encoding=pcm_s16le", "sample_rate=16000",
        "cartesia_version=\(apiVersion)",
      ] + CartesiaKeyterms(vocabulary).terms.map(CartesiaKeyterms.queryItem)
    var components = URLComponents(string: "wss://api.cartesia.ai/stt/websocket")!
    components.percentEncodedQuery = items.joined(separator: "&")
    var request = URLRequest(url: components.url!)
    request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
    return request
  }
}

struct CartesiaRealtimeResponse: Decodable, Equatable {
  let type: String?
  let isFinal: Bool?
  let text: String?
  let title: String?
  let message: String?

  enum CodingKeys: String, CodingKey {
    case type, text, title, message
    case isFinal = "is_final"
  }
}

/// Never retain a URL or an underlying error: the request URL carries dictionary terms, and
/// Foundation keeps it in error userInfo.
struct CartesiaTransportError: LocalizedError, Equatable {
  /// The HTTP status of a refused handshake, or a WebSocket close code.
  let status: Int?

  var httpStatus: Int? {
    guard let status, (400...599).contains(status) else { return nil }
    return status
  }

  var isNormalClosure: Bool {
    status == URLSessionWebSocketTask.CloseCode.normalClosure.rawValue
  }

  var isProviderRejection: Bool {
    httpStatus != nil || [1008, 1009, 1011, 1013].contains(status ?? 0)
  }

  var errorDescription: String? {
    switch status {
    case 401, 403: "Cartesia rejected this API key."
    case 414: "Cartesia refused the request as too large. Shorten the Dictionary and try again."
    case 429, 1013:
      "Cartesia is rate limited or at your plan's connection limit. Wait a moment and try again."
    default: "The Cartesia transcription connection failed. Try again."
    }
  }
}

@MainActor
protocol CartesiaWebSocketTransport: AnyObject {
  /// Starts the handshake and returns once the server has accepted the socket.
  func open() async throws
  func send(_ message: URLSessionWebSocketTask.Message) async throws
  func receive() async throws -> URLSessionWebSocketTask.Message
  func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?)
}

/// Drives audio pacing; tests substitute a manual clock.
@MainActor
struct CartesiaPacingClock {
  var now: () -> ContinuousClock.Instant
  var sleep: (ContinuousClock.Instant) async throws -> Void

  static var continuous: Self {
    Self(now: { ContinuousClock.now }, sleep: { try await ContinuousClock().sleep(until: $0) })
  }
}

@MainActor
private final class URLSessionCartesiaTransport: NSObject, CartesiaWebSocketTransport,
  URLSessionWebSocketDelegate
{
  private var session: URLSession!
  private var task: URLSessionWebSocketTask!
  private var openContinuation: CheckedContinuation<Void, Error>?
  private var closeCode: Int?

  init(request: URLRequest) {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 3
    super.init()
    session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    task = session.webSocketTask(with: request)
  }

  func open() async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      openContinuation = continuation
      AppNetworkPolicy.shared.resume(task)
    }
  }

  func send(_ message: URLSessionWebSocketTask.Message) async throws {
    do { try await task.send(message) } catch { throw sanitizedError() }
  }

  func receive() async throws -> URLSessionWebSocketTask.Message {
    do { return try await task.receive() } catch { throw sanitizedError() }
  }

  func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
    AppNetworkPolicy.shared.forget(task)
    task.cancel(with: closeCode, reason: reason)
    session.invalidateAndCancel()
    finishOpen(.failure(CancellationError()))
  }

  private func finishOpen(_ result: Result<Void, Error>) {
    guard let continuation = openContinuation else { return }
    openContinuation = nil
    continuation.resume(with: result)
  }

  private func sanitizedError() -> CartesiaTransportError {
    if let status = (task.response as? HTTPURLResponse)?.statusCode, status != 101 {
      return CartesiaTransportError(status: status)
    }
    if let closeCode { return CartesiaTransportError(status: closeCode) }
    let code = task.closeCode
    return CartesiaTransportError(status: code == .invalid ? nil : code.rawValue)
  }

  nonisolated func urlSession(
    _ session: URLSession, webSocketTask: URLSessionWebSocketTask,
    didOpenWithProtocol protocol: String?
  ) {
    Task { @MainActor [weak self] in self?.finishOpen(.success(())) }
  }

  nonisolated func urlSession(
    _ session: URLSession, webSocketTask: URLSessionWebSocketTask,
    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?
  ) {
    let code = closeCode.rawValue
    Task { @MainActor [weak self] in self?.closeCode = code }
  }

  nonisolated func urlSession(
    _ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?
  ) {
    Task { @MainActor [weak self] in
      guard let self else { return }
      AppNetworkPolicy.shared.forget(self.task)
      // A refused handshake ends here, with the HTTP status on the task's response.
      self.finishOpen(.failure(self.sanitizedError()))
      self.session.finishTasksAndInvalidate()
    }
  }
}

/// Streams one dictation to Cartesia's manual-finalize endpoint. Both Ink models use it.
@MainActor
final class CartesiaRealtimeClient: RealtimeTranscribing {
  var onTranscript: ((RealtimeTranscriptUpdate) -> Void)?
  var onError: ((Error) -> Void)?

  /// Cartesia expects audio at about the rate it was spoken. In live sessions on both Ink
  /// models (12 per arm, 2026-10-05) a second of audio sent at once transcribed identically
  /// and finished as fast as realtime sending, so that much goes out without waiting: the
  /// audio captured while the socket opened, and the last block at release.
  nonisolated static let burstNanoseconds: Int64 = 1_000_000_000
  /// A longer backlog drains at 1.35× realtime, as in the Meta and Grok clients.
  nonisolated static let catchUpPercent: Int64 = 135

  private let makeTransport: (URLRequest) -> CartesiaWebSocketTransport
  private let connectionTimeout: Duration
  private let finalizationTimeout: Duration
  private let clock: CartesiaPacingClock
  private var transport: CartesiaWebSocketTransport?
  private var receiveTask: Task<Void, Never>?
  private var connectionTimeoutTask: Task<Void, Never>?
  private var finalizationTimeoutTask: Task<Void, Never>?
  private var finishContinuation: CheckedContinuation<String, Error>?
  private var snapshot = TranscriptSnapshot()
  /// Nanoseconds of audio that may be sent right now.
  private var audioBudget = CartesiaRealtimeClient.burstNanoseconds
  private var budgetRefilledAt: ContinuousClock.Instant?
  private var isFinishing = false
  /// The connection whose handshake is still in flight; only that one can time out.
  private var openingConnection: UUID?
  private var timedOutConnection: UUID?
  private var generation = UUID()
  private let logger = Logger(subsystem: "com.danielou.AeriVoice", category: "CartesiaRealtime")

  init(
    connectionTimeout: Duration = .seconds(3),
    finalizationTimeout: Duration = .seconds(3),
    clock: CartesiaPacingClock = .continuous,
    makeTransport: @escaping (URLRequest) -> CartesiaWebSocketTransport = {
      URLSessionCartesiaTransport(request: $0)
    }
  ) {
    self.connectionTimeout = connectionTimeout
    self.finalizationTimeout = finalizationTimeout
    self.clock = clock
    self.makeTransport = makeTransport
  }

  func connect(
    configuration: TranscriptionConfiguration, apiKey: String, vocabulary: [String],
    sessionID: DictationSessionID
  ) async throws {
    cancel()
    guard configuration.provider == .cartesia else {
      throw AppError.provider("The selected transcription model is not available through Cartesia.")
    }
    try AppNetworkPolicy.shared.checkAllowed()

    let connectionGeneration = UUID()
    generation = connectionGeneration
    openingConnection = connectionGeneration
    let transport = makeTransport(
      CartesiaRealtimeRequest.make(
        apiKey: apiKey, model: configuration.modelID, vocabulary: vocabulary))
    self.transport = transport
    connectionTimeoutTask = Task { @MainActor [weak self, connectionTimeout] in
      do { try await Task.sleep(for: connectionTimeout) } catch { return }
      // A handshake that has finished is left alone, even when this sleep ended before the
      // task could be cancelled.
      guard let self, self.openingConnection == connectionGeneration else { return }
      self.timedOutConnection = connectionGeneration
      transport.cancel(with: .goingAway, reason: nil)
    }

    do {
      try await withTaskCancellationHandler {
        try await transport.open()
      } onCancel: {
        Task { @MainActor [weak self] in
          guard let self, self.generation == connectionGeneration else { return }
          self.cancel()
        }
      }
    } catch {
      guard generation == connectionGeneration else { throw CancellationError() }
      let timedOut = timedOutConnection == connectionGeneration
      cancel()
      throw timedOut ? AppError.connectionTimeout : error
    }
    // A newer connection owns the timeout task from here on.
    guard generation == connectionGeneration else { throw CancellationError() }
    openingConnection = nil
    connectionTimeoutTask?.cancel()
    connectionTimeoutTask = nil
    // The timeout can fire in the same turn the handshake completes.
    if timedOutConnection == connectionGeneration {
      cancel()
      throw AppError.connectionTimeout
    }
    receiveTask = Task { @MainActor [weak self] in
      await self?.receiveLoop(transport: transport, generation: connectionGeneration)
    }
  }

  func send(_ frame: RealtimeAudioFrame) async throws {
    guard !frame.audio.isEmpty else { return }
    guard let transport else { throw AppError.provider("Cartesia is not connected.") }
    guard !isFinishing else {
      throw AppError.provider("Cartesia has already ended audio input.")
    }
    let sendGeneration = generation
    let needed = Self.audioNanoseconds(forByteCount: frame.audio.count)
    refillAudioBudget()
    if audioBudget < needed {
      let wait = Self.catchUpWait(forMissingAudio: needed - audioBudget)
      try await clock.sleep(clock.now().advanced(by: wait))
      refillAudioBudget()
    }
    guard generation == sendGeneration, self.transport === transport else {
      throw CancellationError()
    }
    audioBudget -= needed
    try await transport.send(.data(frame.audio))
  }

  /// Live audio arrives at realtime and the budget refills faster than that, so only a
  /// backlog longer than the burst ever waits.
  private func refillAudioBudget() {
    let now = clock.now()
    if let budgetRefilledAt {
      let elapsed = budgetRefilledAt.duration(to: now).components
      let nanoseconds = min(
        Self.burstNanoseconds, elapsed.seconds * 1_000_000_000 + elapsed.attoseconds / 1_000_000_000)
      audioBudget = min(
        Self.burstNanoseconds, audioBudget + max(0, nanoseconds) * Self.catchUpPercent / 100)
    }
    budgetRefilledAt = now
  }

  func finish() async throws -> String {
    guard let transport else { throw AppError.provider("Cartesia is not connected.") }
    guard !isFinishing else {
      throw AppError.provider("Cartesia is already finishing this transcription.")
    }
    let finishGeneration = generation
    return try await withCheckedThrowingContinuation { continuation in
      isFinishing = true
      finishContinuation = continuation
      Task { @MainActor [weak self] in
        do {
          // `finalize` asks for the transcript of everything sent. `close` then ends the
          // session: the server sends `done` once all audio has been transcribed.
          try await transport.send(.string("finalize"))
          try await transport.send(.string("close"))
        } catch {
          guard let self, self.generation == finishGeneration, self.transport === transport else {
            return
          }
          self.complete(.failure(error))
        }
      }
      finalizationTimeoutTask = Task { @MainActor [weak self, finalizationTimeout] in
        do { try await Task.sleep(for: finalizationTimeout) } catch { return }
        guard let self, self.generation == finishGeneration, self.finishContinuation != nil else {
          return
        }
        self.complete(.failure(AppError.finalizeTimeout))
      }
    }
  }

  func cancel() {
    generation = UUID()
    connectionTimeoutTask?.cancel()
    connectionTimeoutTask = nil
    finalizationTimeoutTask?.cancel()
    finalizationTimeoutTask = nil
    receiveTask?.cancel()
    receiveTask = nil
    transport?.cancel(with: .goingAway, reason: nil)
    transport = nil
    if let continuation = finishContinuation {
      finishContinuation = nil
      continuation.resume(throwing: CancellationError())
    }
    snapshot = TranscriptSnapshot()
    audioBudget = Self.burstNanoseconds
    budgetRefilledAt = nil
    isFinishing = false
    openingConnection = nil
    timedOutConnection = nil
  }

  private func receiveLoop(
    transport: CartesiaWebSocketTransport, generation connectionGeneration: UUID
  ) async {
    do {
      while !Task.isCancelled, generation == connectionGeneration, self.transport === transport {
        try consume(Self.decode(try await transport.receive()), generation: connectionGeneration)
      }
    } catch is CancellationError {
    } catch {
      guard generation == connectionGeneration, self.transport === transport else { return }
      guard isFinishing else {
        onError?(error)
        return
      }
      // The server closes normally only after it has transcribed everything it was sent.
      if (error as? CartesiaTransportError)?.isNormalClosure == true {
        logger.info("Cartesia closed before done; using the transcript received so far")
        complete(transcriptResult())
      } else {
        complete(.failure(error))
      }
    }
  }

  private func consume(
    _ response: CartesiaRealtimeResponse, generation connectionGeneration: UUID
  ) throws {
    guard generation == connectionGeneration else { return }
    switch response.type {
    case "transcript":
      let text = response.text ?? ""
      let isFinal = response.isFinal == true
      if isFinal {
        // Final chunks are deltas. Cartesia requires joining them exactly as received:
        // trimming or adding spaces joins or splits words.
        snapshot = TranscriptSnapshot(confirmed: snapshot.confirmed + text)
      } else {
        snapshot.provisional = text
      }
      onTranscript?(
        RealtimeTranscriptUpdate(
          snapshot: snapshot,
          hasFinalText: isFinal && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          finalAudioProcessedMS: nil, totalAudioProcessedMS: nil))
    case "done":
      if isFinishing { complete(transcriptResult()) }
    case "error":
      throw AppError.provider(
        "Cartesia: \(response.message ?? response.title ?? "transcription failed.")")
    default:
      // `flush_done` acknowledges `finalize`; `done` is what ends the session.
      break
    }
  }

  private func transcriptResult() -> Result<String, Error> {
    let text = snapshot.displayText.trimmingCharacters(in: .whitespacesAndNewlines)
    return text.isEmpty ? .failure(AppError.emptyTranscript) : .success(text)
  }

  private func complete(_ result: Result<String, Error>) {
    guard let continuation = finishContinuation else { return }
    finishContinuation = nil
    isFinishing = false
    finalizationTimeoutTask?.cancel()
    finalizationTimeoutTask = nil
    receiveTask?.cancel()
    receiveTask = nil
    let closeCode: URLSessionWebSocketTask.CloseCode
    switch result {
    case .success: closeCode = .normalClosure
    case .failure: closeCode = .goingAway
    }
    transport?.cancel(with: closeCode, reason: nil)
    transport = nil
    continuation.resume(with: result)
  }

  /// 16 kHz 16-bit mono PCM is 32,000 bytes per second.
  nonisolated static func audioNanoseconds(forByteCount byteCount: Int) -> Int64 {
    Int64(byteCount) * 31_250
  }

  /// How long the budget takes to regain this much audio at the catch-up speed.
  nonisolated static func catchUpWait(forMissingAudio nanoseconds: Int64) -> Duration {
    .nanoseconds((nanoseconds * 100 + catchUpPercent - 1) / catchUpPercent)
  }

  nonisolated private static func decode(
    _ message: URLSessionWebSocketTask.Message
  ) throws -> CartesiaRealtimeResponse {
    let data: Data
    switch message {
    case .data(let value): data = value
    case .string(let value): data = Data(value.utf8)
    @unknown default:
      throw AppError.provider("Cartesia returned an unsupported WebSocket message.")
    }
    return try JSONDecoder().decode(CartesiaRealtimeResponse.self, from: data)
  }
}

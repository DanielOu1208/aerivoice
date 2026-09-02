import Foundation
import OSLog
import Security

struct MetaRealtimeHandshake: Encodable, Equatable {
  struct Authorization: Encodable, Equatable {
    let accessToken: String
  }

  let authorization: Authorization
  let audioEncoding: String
  let model: String
  let mode: String
  let partialMode: String
  let emitAudioProgress: Bool
  let keywords: [String]?
  let zdrOverride: Bool

  init(
    apiKey: String, configuration: TranscriptionConfiguration, vocabulary: [String]
  ) {
    authorization = Authorization(accessToken: "Bearer \(apiKey)")
    audioEncoding = "PCM_16KHZ"
    model = configuration.modelID
    mode = "PUSH_TO_TALK"
    partialMode = "CUMULATIVE"
    emitAudioProgress = false
    keywords = vocabulary.isEmpty ? nil : vocabulary
    zdrOverride = true
  }
}

struct MetaRealtimeResponse: Decodable, Equatable {
  let type: String?
  let sessionID: String?
  let transcript: String?
  let final: Bool?
  let message: String?

  enum CodingKeys: String, CodingKey {
    case type, transcript, final, message
    case sessionID = "sessionId"
  }

  var transcriptUpdate: RealtimeTranscriptUpdate? {
    guard type == "transcript", let transcript else { return nil }
    let isFinal = final == true
    let snapshot =
      isFinal
      ? TranscriptSnapshot(confirmed: transcript)
      : TranscriptSnapshot(provisional: transcript)
    return RealtimeTranscriptUpdate(
      snapshot: snapshot,
      hasFinalText: isFinal
        && !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      finalAudioProcessedMS: nil, totalAudioProcessedMS: nil)
  }
}

@MainActor
protocol MetaWebSocketTransport: AnyObject {
  func resume()
  func send(_ message: URLSessionWebSocketTask.Message) async throws
  func receive() async throws -> URLSessionWebSocketTask.Message
  func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?)
}

struct MetaWebSocketTransportError: Error {
  let underlying: Error
  let closeCode: Int?
}

private struct MetaWebSocketTermination {
  let closeCode: Int?
  let error: Error?
}

@MainActor
protocol MetaPacingClock {
  var now: ContinuousClock.Instant { get }
  func sleep(until deadline: ContinuousClock.Instant) async throws
}

@MainActor
private struct ContinuousMetaPacingClock: MetaPacingClock {
  private let clock = ContinuousClock()

  var now: ContinuousClock.Instant { clock.now }

  func sleep(until deadline: ContinuousClock.Instant) async throws {
    try await clock.sleep(until: deadline)
  }
}

@MainActor
private final class URLSessionMetaWebSocketTransport: NSObject, MetaWebSocketTransport,
  URLSessionWebSocketDelegate
{
  private var session: URLSession!
  private var task: URLSessionWebSocketTask!
  private var termination: MetaWebSocketTermination?
  private var terminationWaiters: [CheckedContinuation<MetaWebSocketTermination, Never>] = []

  init(url: URL) {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 3
    super.init()
    session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    task = session.webSocketTask(with: url)
  }

  func resume() { task.resume() }
  func send(_ message: URLSessionWebSocketTask.Message) async throws {
    do {
      try await task.send(message)
    } catch {
      let termination = await waitForTermination()
      throw MetaWebSocketTransportError(
        underlying: termination.error ?? error, closeCode: termination.closeCode)
    }
  }
  func receive() async throws -> URLSessionWebSocketTask.Message {
    do {
      return try await task.receive()
    } catch {
      let termination = await waitForTermination()
      throw MetaWebSocketTransportError(
        underlying: termination.error ?? error, closeCode: termination.closeCode)
    }
  }
  func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
    task.cancel(with: closeCode, reason: reason)
    session.invalidateAndCancel()
  }

  private func waitForTermination() async -> MetaWebSocketTermination {
    if let termination { return termination }
    return await withCheckedContinuation { terminationWaiters.append($0) }
  }

  private func recordTermination(closeCode: Int?, error: Error?) {
    guard termination == nil else { return }
    let termination = MetaWebSocketTermination(closeCode: closeCode, error: error)
    self.termination = termination
    let waiters = terminationWaiters
    terminationWaiters.removeAll()
    waiters.forEach { $0.resume(returning: termination) }
    session.finishTasksAndInvalidate()
  }

  nonisolated func urlSession(
    _ session: URLSession, webSocketTask: URLSessionWebSocketTask,
    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?
  ) {
    Task { @MainActor [weak self] in
      self?.recordTermination(closeCode: closeCode.rawValue, error: nil)
    }
  }

  nonisolated func urlSession(
    _ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?
  ) {
    Task { @MainActor [weak self] in
      guard let self, self.termination == nil else { return }
      let code = self.task.closeCode
      self.recordTermination(
        closeCode: code == .invalid ? nil : code.rawValue, error: error)
    }
  }
}

@MainActor
final class MetaRealtimeClient: NSObject, RealtimeTranscribing {
  var onTranscript: ((RealtimeTranscriptUpdate) -> Void)?
  var onError: ((Error) -> Void)?

  private let makeTransport: (URL) -> MetaWebSocketTransport
  private let acknowledgementTimeout: Duration
  private let finalizationTimeout: Duration
  private let pacingClock: any MetaPacingClock
  private var transport: MetaWebSocketTransport?
  private var receiveTask: Task<Void, Never>?
  private var acknowledgementTimeoutTask: Task<Void, Never>?
  private var finalizationTimeoutTask: Task<Void, Never>?
  private var acknowledgementContinuation: CheckedContinuation<MetaRealtimeResponse, Error>?
  private var finishContinuation: CheckedContinuation<String, Error>?
  private var currentTranscript = ""
  private var finalTranscript: String?
  private var nextAudioDeadline: ContinuousClock.Instant?
  private var isFinishing = false
  private var endStreamSent = false
  private var pendingTerminationError: Error?
  private var generation = UUID()
  private let logger = Logger(subsystem: "com.danielou.AeriVoice", category: "MetaRealtime")

  init(
    acknowledgementTimeout: Duration = .seconds(3),
    finalizationTimeout: Duration = .seconds(3),
    pacingClock: any MetaPacingClock = ContinuousMetaPacingClock(),
    makeTransport: @escaping (URL) -> MetaWebSocketTransport = {
      URLSessionMetaWebSocketTransport(url: $0)
    }
  ) {
    self.acknowledgementTimeout = acknowledgementTimeout
    self.finalizationTimeout = finalizationTimeout
    self.pacingClock = pacingClock
    self.makeTransport = makeTransport
  }

  func connect(
    configuration: TranscriptionConfiguration, apiKey: String, vocabulary: [String],
    sessionID: DictationSessionID
  ) async throws {
    cancel()
    guard configuration.provider == .meta else {
      throw AppError.provider(
        "The selected transcription model is not available through Meta Model API.")
    }

    let connectionGeneration = UUID()
    generation = connectionGeneration
    var components = URLComponents(string: "wss://api.meta.ai/v1/asr/realtime")!
    components.queryItems = [
      URLQueryItem(name: "sessionId", value: sessionID.rawValue.uuidString)
    ]
    let transport = makeTransport(components.url!)
    self.transport = transport
    transport.resume()

    let handshake = MetaRealtimeHandshake(
      apiKey: apiKey, configuration: configuration, vocabulary: vocabulary)
    let handshakeJSON = String(decoding: try JSONEncoder().encode(handshake), as: UTF8.self)

    do {
      let acknowledgement = try await waitForAcknowledgement(
        handshakeJSON: handshakeJSON, transport: transport, generation: connectionGeneration)
      guard generation == connectionGeneration else { throw CancellationError() }
      if acknowledgement.type == "error" {
        throw AppError.provider(
          acknowledgement.message ?? "Meta Model API rejected the transcription session.")
      }
      guard acknowledgement.sessionID?.isEmpty == false else {
        throw AppError.provider("Meta Model API returned an invalid session acknowledgement.")
      }
    } catch {
      let surfacedError = closeError(fallback: error)
      if generation == connectionGeneration { cancel() }
      throw surfacedError
    }

    receiveTask = Task { @MainActor [weak self] in
      await self?.receiveLoop(transport: transport, generation: connectionGeneration)
    }
  }

  func send(_ frame: RealtimeAudioFrame) async throws {
    guard !frame.audio.isEmpty else { return }
    guard let transport else {
      throw AppError.provider("Meta Model API is not connected.")
    }
    guard !isFinishing else {
      throw AppError.provider("Meta Model API has already ended audio input.")
    }
    let sendGeneration = generation
    let speedMultiplier = frame.queuedBytesAfterFrame > 3_200 ? 1.35 : 1.0
    let frameDuration = Self.pacingOffset(
      forByteCount: frame.audio.count, speedMultiplier: speedMultiplier)
    let frameStart: ContinuousClock.Instant
    if let nextAudioDeadline, pacingClock.now < nextAudioDeadline {
      try await pacingClock.sleep(until: nextAudioDeadline)
      frameStart = pacingClock.now
    } else {
      frameStart = pacingClock.now
    }
    guard generation == sendGeneration, self.transport === transport else {
      throw CancellationError()
    }
    do {
      try await transport.send(.data(frame.audio))
    } catch {
      throw closeError(fallback: error)
    }
    nextAudioDeadline = frameStart.advanced(by: frameDuration)
  }

  func finish() async throws -> String {
    guard let transport else {
      throw AppError.provider("Meta Model API is not connected.")
    }
    guard !isFinishing else {
      throw AppError.provider("Meta Model API is already finishing this transcription.")
    }
    let finishGeneration = generation
    return try await withCheckedThrowingContinuation { continuation in
      isFinishing = true
      finishContinuation = continuation
      Task { @MainActor [weak self] in
        do {
          try await transport.send(.string(#"{"type":"endStream"}"#))
          guard let self, self.generation == finishGeneration, self.transport === transport,
            self.finishContinuation != nil
          else { return }
          self.endStreamSent = true
          if let pendingTerminationError = self.pendingTerminationError {
            self.pendingTerminationError = nil
            self.finishAfterTermination(pendingTerminationError)
          }
        } catch {
          guard let self, self.generation == finishGeneration, self.transport === transport else {
            return
          }
          self.complete(.failure(self.closeError(fallback: error)), cancelTransport: true)
        }
      }
      finalizationTimeoutTask = Task { @MainActor [weak self] in
        try? await Task.sleep(for: self?.finalizationTimeout ?? .zero)
        guard let self, self.generation == finishGeneration, self.finishContinuation != nil else {
          return
        }
        self.complete(.failure(AppError.finalizeTimeout), cancelTransport: true)
      }
    }
  }

  func cancel() {
    generation = UUID()
    acknowledgementTimeoutTask?.cancel()
    acknowledgementTimeoutTask = nil
    finalizationTimeoutTask?.cancel()
    finalizationTimeoutTask = nil
    receiveTask?.cancel()
    receiveTask = nil
    transport?.cancel(with: .goingAway, reason: nil)
    transport = nil
    if let continuation = acknowledgementContinuation {
      continuation.resume(throwing: CancellationError())
      acknowledgementContinuation = nil
    }
    if let continuation = finishContinuation {
      continuation.resume(throwing: CancellationError())
      finishContinuation = nil
    }
    currentTranscript = ""
    finalTranscript = nil
    nextAudioDeadline = nil
    isFinishing = false
    endStreamSent = false
    pendingTerminationError = nil
  }

  private func waitForAcknowledgement(
    handshakeJSON: String, transport: MetaWebSocketTransport,
    generation connectionGeneration: UUID
  ) async throws -> MetaRealtimeResponse {
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        acknowledgementContinuation = continuation
        receiveTask = Task { @MainActor [weak self] in
          do {
            try await transport.send(.string(handshakeJSON))
            let response = try Self.decode(try await transport.receive())
            self?.completeAcknowledgement(
              .success(response), generation: connectionGeneration)
          } catch {
            guard let self else { return }
            self.completeAcknowledgement(
              .failure(self.closeError(fallback: error)),
              generation: connectionGeneration)
          }
        }
        acknowledgementTimeoutTask = Task { @MainActor [weak self] in
          do {
            try await Task.sleep(for: self?.acknowledgementTimeout ?? .zero)
          } catch {
            return
          }
          guard let self, self.generation == connectionGeneration,
            self.acknowledgementContinuation != nil
          else { return }
          transport.cancel(with: .goingAway, reason: nil)
          self.completeAcknowledgement(
            .failure(AppError.connectionTimeout), generation: connectionGeneration)
        }
      }
    } onCancel: {
      Task { @MainActor [weak self] in
        guard let self, self.generation == connectionGeneration else { return }
        self.cancel()
      }
    }
  }

  private func completeAcknowledgement(
    _ result: Result<MetaRealtimeResponse, Error>, generation connectionGeneration: UUID
  ) {
    guard generation == connectionGeneration, let continuation = acknowledgementContinuation else {
      return
    }
    acknowledgementContinuation = nil
    acknowledgementTimeoutTask?.cancel()
    acknowledgementTimeoutTask = nil
    receiveTask = nil
    continuation.resume(with: result)
  }

  private func receiveLoop(
    transport: MetaWebSocketTransport, generation connectionGeneration: UUID
  ) async {
    do {
      while !Task.isCancelled, generation == connectionGeneration, self.transport === transport {
        try consume(Self.decode(try await transport.receive()), generation: connectionGeneration)
      }
    } catch is CancellationError {
    } catch {
      guard generation == connectionGeneration, self.transport === transport else { return }
      if isFinishing {
        if endStreamSent {
          finishAfterTermination(error)
        } else {
          pendingTerminationError = error
        }
      } else {
        onError?(closeError(fallback: error))
      }
    }
  }

  private func consume(
    _ response: MetaRealtimeResponse, generation connectionGeneration: UUID
  ) throws {
    guard generation == connectionGeneration else { return }
    if response.type == "error" {
      throw AppError.provider(response.message ?? "Meta Model API returned a transcription error.")
    }
    guard let update = response.transcriptUpdate else { return }
    currentTranscript = update.snapshot.displayText
    onTranscript?(update)
    guard response.final == true else { return }
    finalTranscript = currentTranscript
  }

  private func finishAfterTermination(_ error: Error) {
    let transportError = error as? MetaWebSocketTransportError
    let closeCode = transportError?.closeCode
    let fallback = transportError?.underlying ?? error
    let isNormalClose = closeCode == URLSessionWebSocketTask.CloseCode.normalClosure.rawValue
    let isGracefulTLSClose = closeCode == nil && Self.isGracefulTLSClosure(fallback)

    guard endStreamSent, isNormalClose || isGracefulTLSClose else {
      complete(.failure(closeError(fallback: error)), cancelTransport: true)
      return
    }

    let transcript = finalTranscript ?? currentTranscript
    do {
      let validatedTranscript = try validated(transcript)
      let source = finalTranscript == nil ? "cumulative-recovery" : "provider-final"
      let code = closeCode ?? -1
      logger.info(
        "Meta realtime completed closeCode=\(code, privacy: .public) source=\(source, privacy: .public)")
      complete(.success(validatedTranscript), cancelTransport: false)
    } catch {
      complete(.failure(error), cancelTransport: false)
    }
  }

  private func complete(_ result: Result<String, Error>, cancelTransport: Bool) {
    guard let continuation = finishContinuation else { return }
    isFinishing = false
    finishContinuation = nil
    finalizationTimeoutTask?.cancel()
    finalizationTimeoutTask = nil
    pendingTerminationError = nil
    if cancelTransport { transport?.cancel(with: .goingAway, reason: nil) }
    transport = nil
    continuation.resume(with: result)
  }

  private func validated(_ transcript: String) throws -> String {
    let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw AppError.emptyTranscript }
    return trimmed
  }

  private func closeError(fallback: Error) -> Error {
    guard let transportError = fallback as? MetaWebSocketTransportError else { return fallback }
    let code = transportError.closeCode ?? -1
    let category: String
    let surfacedError: Error
    switch transportError.closeCode {
    case 1013:
      category = "rate-limited"
      surfacedError = AppError.provider(
        "Meta Model API is rate limited. Wait a moment and try again.")
    case URLSessionWebSocketTask.CloseCode.policyViolation.rawValue:
      category = "policy"
      surfacedError = AppError.provider("Meta Model API rejected the request or audio pacing.")
    case URLSessionWebSocketTask.CloseCode.internalServerError.rawValue:
      category = "backend"
      surfacedError = AppError.provider(
        "Meta Model API had a temporary internal error. Try again.")
    default:
      category = transportError.closeCode == nil ? "transport" : "websocket"
      surfacedError = transportError.underlying
    }
    logger.error(
      "Meta realtime failed closeCode=\(code, privacy: .public) category=\(category, privacy: .public)")
    return surfacedError
  }

  nonisolated static func pacingOffset(
    forByteCount byteCount: Int, speedMultiplier: Double = 1.0
  ) -> Duration {
    let effectiveMultiplier = max(1.0, speedMultiplier)
    return .nanoseconds(
      Int64(
        (Double(byteCount) / (32_000 * effectiveMultiplier) * 1_000_000_000).rounded()))
  }

  nonisolated private static func isGracefulTLSClosure(_ error: Error) -> Bool {
    let error = error as NSError
    if error.domain == NSOSStatusErrorDomain && error.code == Int(errSSLClosedGraceful) {
      return true
    }
    guard let underlying = error.userInfo[NSUnderlyingErrorKey] as? Error else { return false }
    return isGracefulTLSClosure(underlying)
  }

  nonisolated private static func decode(
    _ message: URLSessionWebSocketTask.Message
  ) throws -> MetaRealtimeResponse {
    let data: Data
    switch message {
    case .data(let value): data = value
    case .string(let value): data = Data(value.utf8)
    @unknown default:
      throw AppError.provider("Meta Model API returned an unsupported WebSocket message.")
    }
    return try JSONDecoder().decode(MetaRealtimeResponse.self, from: data)
  }
}

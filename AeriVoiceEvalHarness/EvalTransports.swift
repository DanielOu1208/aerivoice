import Foundation

/// What one provider's server says at each point of a scripted session.
@MainActor
struct EvalProviderDialect {
  /// Where the provider accepts or refuses a connection.
  enum Connection { case onOpen, onFirstTextMessage, onFirstReceive }

  let connection: Connection
  /// What the server says once it accepts the connection.
  var greeting: [String: Any]? = nil
  let partial: (String) -> [String: Any]
  /// Whether a text message from the client ends audio input.
  let endsAudio: (String) -> Bool
  let final: (String) -> [[String: Any]]
  /// What the server answers to other text messages after audio has ended.
  var replies: [String: [String: Any]] = [:]
  /// What a receive throws once the final transcript is read, when the server closes then.
  var closure: Error? = nil

  static let soniox = Self(
    connection: .onFirstTextMessage,
    partial: { ["tokens": [["text": $0, "is_final": false]]] },
    endsAudio: \.isEmpty,
    final: { [["tokens": [["text": $0, "is_final": true]], "finished": true]] })

  static let meta = Self(
    connection: .onFirstTextMessage, greeting: ["type": "ack", "sessionId": "evaluation"],
    partial: { ["type": "transcript", "transcript": $0, "final": false] },
    endsAudio: { messageType($0) == "endStream" },
    final: { [["type": "transcript", "transcript": $0, "final": true]] },
    closure: MetaWebSocketTransportError(
      underlying: URLError(.networkConnectionLost),
      closeCode: URLSessionWebSocketTask.CloseCode.normalClosure.rawValue))

  static let grok = Self(
    connection: .onFirstReceive, greeting: ["type": "transcript.created"],
    partial: {
      ["type": "transcript.partial", "text": $0, "start": 0, "duration": 0.25,
       "is_final": false, "speech_final": false]
    },
    endsAudio: { messageType($0) == "audio.done" },
    final: { [["type": "transcript.done", "text": $0]] })

  /// Cartesia's commands are bare words: `finalize` returns the transcript, `close` ends the session.
  static let cartesia = Self(
    connection: .onOpen,
    partial: { ["type": "transcript", "is_final": false, "text": $0] },
    endsAudio: { $0 == "finalize" },
    final: { [["type": "transcript", "is_final": true, "text": $0], ["type": "flush_done"]] },
    replies: ["close": ["type": "done"]])

  private static func messageType(_ text: String) -> String? {
    let object = try? JSONSerialization.jsonObject(with: Data(text.utf8))
    return (object as? [String: Any])?["type"] as? String
  }
}

/// Responds below the real clients: handshakes, JSON encoding and parsing still run in production code.
@MainActor
final class EvalScriptedSocket: RealtimeWebSocketTransport {
  private let dialect: EvalProviderDialect
  private let script: ControlledResponses
  private let text: String
  private var messages: [URLSessionWebSocketTask.Message] = []
  private var waiter: CheckedContinuation<URLSessionWebSocketTask.Message, Error>?
  private var cancelled = false
  private var receiving = false
  private var sentPartial = false
  private var closePending = false

  init(dialect: EvalProviderDialect, script: ControlledResponses, text: String) {
    self.dialect = dialect; self.script = script; self.text = text
  }
  func invalidate() { cancel(with: .goingAway, reason: nil) }
  func ping() async throws { if cancelled { throw CancellationError() } }

  func open() async throws {
    if dialect.connection == .onOpen { try await connect() }
  }

  func send(_ message: URLSessionWebSocketTask.Message) async throws {
    guard !cancelled else { throw CancellationError() }
    switch message {
    case .data:
      guard !sentPartial else { return }
      sentPartial = true
      if script.fault == "malformed_stt" { enqueue(.string("invalid-json")); return }
      try enqueue(dialect.partial(text))
    case .string(let value) where dialect.endsAudio(value):
      guard script.fault != "finalize_timeout" else { return }
      try await pause(script.finalizeDelayMs)
      for message in dialect.final(text) { try enqueue(message) }
      closePending = dialect.closure != nil
    case .string(let value):
      if let reply = dialect.replies[value] {
        if script.fault != "finalize_timeout" { try enqueue(reply) }
      } else if dialect.connection == .onFirstTextMessage {
        try await connect()
      }
    @unknown default: throw EvalError.internalFailure
    }
  }

  func receive() async throws -> URLSessionWebSocketTask.Message {
    if cancelled { throw CancellationError() }
    if dialect.connection == .onFirstReceive, !receiving {
      receiving = true
      try await connect()
    }
    if !messages.isEmpty { return messages.removeFirst() }
    if closePending, let closure = dialect.closure { throw closure }
    return try await withCheckedThrowingContinuation { waiter = $0 }
  }

  func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
    cancelled = true
    waiter?.resume(throwing: CancellationError())
    waiter = nil
    messages.removeAll()
  }

  private func connect() async throws {
    try await pause(script.connectDelayMs)
    if script.fault == "connection" { throw URLError(.cannotConnectToHost) }
    if let greeting = dialect.greeting { try enqueue(greeting) }
  }

  private func pause(_ milliseconds: Double?) async throws {
    try await Task.sleep(for: .milliseconds(milliseconds ?? 0))
    guard !cancelled else { throw CancellationError() }
  }

  private func enqueue(_ object: [String: Any]) throws {
    let data = try JSONSerialization.data(withJSONObject: object)
    enqueue(.data(data))
  }

  private func enqueue(_ message: URLSessionWebSocketTask.Message) {
    guard !cancelled else { return }
    if let waiter { self.waiter = nil; waiter.resume(returning: message) }
    else { messages.append(message) }
  }
}

/// Captures every HTTP request in the injected ephemeral session, including warming requests.
final class EvalHTTPProtocol: URLProtocol, @unchecked Sendable {
  private static let configurationLock = NSLock()
  nonisolated(unsafe) private static var script = ControlledResponses()
  nonisolated(unsafe) private static var output = ""
  private let deliveryLock = NSRecursiveLock()
  private var stopped = false
  private var delivery: DispatchWorkItem?

  static func configure(script: ControlledResponses, output: String) {
    configurationLock.withLock { self.script = script; self.output = output }
  }
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    let (script, output) = Self.configurationLock.withLock { (Self.script, Self.output) }
    let warming = request.url?.path.hasSuffix("tcp_warming") == true
    let item = DispatchWorkItem { [weak self] in
      guard let self else { return }
      self.deliveryLock.withLock {
        guard !self.stopped, let url = self.request.url else { return }
        do {
          let content = try JSONSerialization.data(withJSONObject: ["text": script.fault == "cleanup_empty" ? "" : output])
          let response = try JSONSerialization.data(withJSONObject: [
            "choices": [["message": ["content": String(decoding: content, as: UTF8.self)]]],
          ])
          let status = !warming && script.fault == "cleanup_http" ? script.httpStatus ?? 500 : 200
          let http = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                     headerFields: ["Content-Type": "application/json"])!
          self.client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
          self.client?.urlProtocol(self, didLoad: warming ? Data("{}".utf8) : response)
          self.client?.urlProtocolDidFinishLoading(self)
        } catch { self.client?.urlProtocol(self, didFailWithError: EvalError.internalFailure) }
      }
    }
    delivery = item
    DispatchQueue.global(qos: .userInitiated).asyncAfter(
      deadline: .now() + (warming ? 0 : script.cleanupDelayMs ?? 0) / 1_000, execute: item)
  }

  override func stopLoading() {
    deliveryLock.withLock { stopped = true; delivery?.cancel(); delivery = nil }
  }
}

@MainActor
final class EvalTranscriber: RealtimeTranscribing {
  var onTranscript: ((RealtimeTranscriptUpdate) -> Void)?
  var onError: ((Error) -> Void)?
  var onAudioSent: ((Int) -> Void)?
  var onConnectionEvent: ((String) -> Void)?
  var reportsAudioSends: Bool { client.reportsAudioSends }
  var hasPreparedConnection: Bool { client.hasPreparedConnection }
  let client: RealtimeTranscribing
  private let events: EvalEvents
  private(set) var rawText = ""
  private(set) var activeOperations = 0
  private(set) var sentBytes = 0

  init(client: RealtimeTranscribing, events: EvalEvents) {
    self.client = client; self.events = events
    client.onTranscript = { [weak self] update in
      guard let self else { return }
      self.events.emit("transcript", ["text": update.snapshot.displayText, "final": update.hasFinalText])
      self.onTranscript?(update)
    }
    client.onError = { [weak self] error in self?.onError?(error) }
    client.onAudioSent = { [weak self] count in
      guard let self else { return }
      self.recordSent(count, actualWrite: true)
      self.onAudioSent?(count)
    }
    client.onConnectionEvent = { [weak self] name in
      guard let self else { return }
      let allowed = ["preparationStarted", "preparationReady", "preparationExpired", "preparationFailed",
                     "preparationInvalidated", "preparationHit", "preparationMiss", "audioDoneSent"]
      guard allowed.contains(name) else { return }
      self.events.emit("connection_event", ["name": name])
      self.onConnectionEvent?(name)
    }
  }
  private func recordSent(_ count: Int, actualWrite: Bool) {
    sentBytes += count
    events.emit("audio_sent", ["bytes": count, "cumulative_bytes": sentBytes,
                               "actual_transport_write": actualWrite])
  }
  func reset() { rawText = ""; sentBytes = 0 }
  func connect(configuration: TranscriptionConfiguration, apiKey: String, vocabulary: [String], sessionID: DictationSessionID) async throws {
    activeOperations += 1; defer { activeOperations -= 1 }
    try await client.connect(configuration: configuration, apiKey: apiKey, vocabulary: vocabulary, sessionID: sessionID)
  }
  func send(_ frame: RealtimeAudioFrame) async throws {
    activeOperations += 1; defer { activeOperations -= 1 }
    try await client.send(frame)
    if !client.reportsAudioSends { recordSent(frame.audio.count, actualWrite: false) }
  }
  func flushAudio() async throws {
    activeOperations += 1; defer { activeOperations -= 1 }
    try await client.flushAudio()
  }
  func prepareConnection(configuration: TranscriptionConfiguration, apiKey: String, vocabulary: [String]) async -> Bool {
    activeOperations += 1; defer { activeOperations -= 1 }
    return await client.prepareConnection(configuration: configuration, apiKey: apiKey, vocabulary: vocabulary)
  }
  func invalidatePreparedConnection() { client.invalidatePreparedConnection() }
  func cancelActiveConnection() { client.cancelActiveConnection() }
  func finish() async throws -> String {
    activeOperations += 1; defer { activeOperations -= 1 }
    let text = try await client.finish()
    rawText = text
    return text
  }
  func cancel() { client.cancel() }
}

final class EvalCleaner: CleaningText, @unchecked Sendable {
  private let client: CleaningText
  private let events: EvalEvents
  private let lock = NSLock()
  private var active = 0
  var activeOperations: Int { lock.withLock { active } }
  init(client: CleaningText, events: EvalEvents) { self.client = client; self.events = events }
  func warmUp(configuration: CleanupConfiguration, apiKey: String) async {
    lock.withLock { active += 1 }; defer { lock.withLock { active -= 1 } }
    let session = events.session
    events.emit("warming_started", session: session)
    await client.warmUp(configuration: configuration, apiKey: apiKey)
    events.emit("warming_finished", session: session)
  }
  func clean(_ text: String, instructions: CleanupInstructions, configuration: CleanupConfiguration, apiKey: String) async throws -> CleanupTextResult {
    lock.withLock { active += 1 }; defer { lock.withLock { active -= 1 } }
    let session = events.session
    events.emit("cleanup_started", ["raw_text": text], session: session)
    do {
      let result = try await client.clean(text, instructions: instructions, configuration: configuration, apiKey: apiKey)
      events.emit("cleanup_finished", ["output_text": result.text, "metrics": evalCleanupMetrics(result.metrics)], session: session)
      return result
    } catch {
      var details: [String: Any] = ["category": evalFailure(error)]
      if let failure = error as? ProviderHTTPError {
        details["http_status"] = failure.statusCode
        if let metrics = failure.cleanupMetrics { details["metrics"] = evalCleanupMetrics(metrics) }
      } else if let failure = error as? CleanupNetworkError {
        details["metrics"] = evalCleanupMetrics(failure.cleanupMetrics)
      }
      events.emit("cleanup_failed", details, session: session)
      throw error
    }
  }
}

func evalCleanupMetrics(_ metrics: CleanupRequestMetrics) -> [String: Any] {
  var result: [String: Any] = [:]
  result["actual_model"] = metrics.actualModel
  result["selected_provider"] = metrics.selectedProvider
  result["http_status"] = metrics.httpStatus
  result["request_encoding_ms"] = metrics.requestEncodingMS
  result["network_request_ms"] = metrics.networkRequestMS
  result["response_decoding_ms"] = metrics.responseDecodingMS
  result["prompt_tokens"] = metrics.promptTokens
  result["completion_tokens"] = metrics.completionTokens
  if let value = metrics.providerTiming { result["provider_timing"] = EvalEvents.object(value) }
  if let value = metrics.networkTiming { result["network_timing"] = EvalEvents.object(value) }
  return result
}

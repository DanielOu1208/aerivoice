import Foundation

/// Responds below the real clients: handshakes, JSON encoding and parsing still run in production code.
@MainActor
final class EvalScriptedSocket: SonioxWebSocketTransport, MetaWebSocketTransport {
  private let provider: TranscriptionProvider
  private let script: ControlledResponses
  private let text: String
  private var messages: [URLSessionWebSocketTask.Message] = []
  private var waiter: CheckedContinuation<URLSessionWebSocketTask.Message, Error>?
  private var cancelled = false
  private var sentPartial = false
  private var normalClosePending = false

  init(provider: TranscriptionProvider, script: ControlledResponses, text: String) {
    self.provider = provider; self.script = script; self.text = text
  }
  func resume() {}
  func invalidate() { cancel(with: .goingAway, reason: nil) }

  func send(_ message: URLSessionWebSocketTask.Message) async throws {
    guard !cancelled else { throw CancellationError() }
    switch message {
    case .data:
      if !sentPartial {
        sentPartial = true
        if script.fault == "malformed_stt" { enqueue(.string("invalid-json")); return }
        if provider == .soniox {
          try enqueue(["tokens": [["text": text, "is_final": false]]])
        } else { try enqueue(["type": "transcript", "transcript": text, "final": false]) }
      }
    case .string(let value):
      let object = (try? JSONSerialization.jsonObject(with: Data(value.utf8))) as? [String: Any]
      let finishing = provider == .soniox ? value.isEmpty : object?["type"] as? String == "endStream"
      if finishing {
        if script.fault == "finalize_timeout" { return }
        try await Task.sleep(for: .milliseconds(script.finalizeDelayMs ?? 0))
        guard !cancelled else { throw CancellationError() }
        if provider == .soniox {
          try enqueue(["tokens": [["text": text, "is_final": true]], "finished": true])
        } else {
          try enqueue(["type": "transcript", "transcript": text, "final": true])
          normalClosePending = true
        }
      } else {
        try await Task.sleep(for: .milliseconds(script.connectDelayMs ?? 0))
        guard !cancelled else { throw CancellationError() }
        if script.fault == "connection" { throw URLError(.cannotConnectToHost) }
        if provider == .meta { try enqueue(["type": "ack", "sessionId": "evaluation"]) }
      }
    @unknown default: throw EvalError.internalFailure
    }
  }

  func receive() async throws -> URLSessionWebSocketTask.Message {
    if cancelled { throw CancellationError() }
    if !messages.isEmpty { return messages.removeFirst() }
    if normalClosePending {
      throw MetaWebSocketTransportError(underlying: URLError(.networkConnectionLost),
                                        closeCode: URLSessionWebSocketTask.CloseCode.normalClosure.rawValue)
    }
    return try await withCheckedThrowingContinuation { waiter = $0 }
  }

  func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
    cancelled = true
    waiter?.resume(throwing: CancellationError())
    waiter = nil
    messages.removeAll()
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
  }
  func reset() { rawText = ""; sentBytes = 0 }
  func connect(configuration: TranscriptionConfiguration, apiKey: String, vocabulary: [String], sessionID: DictationSessionID) async throws {
    activeOperations += 1; defer { activeOperations -= 1 }
    try await client.connect(configuration: configuration, apiKey: apiKey, vocabulary: vocabulary, sessionID: sessionID)
  }
  func send(_ frame: RealtimeAudioFrame) async throws {
    activeOperations += 1; defer { activeOperations -= 1 }
    try await client.send(frame)
    sentBytes += frame.audio.count
  }
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

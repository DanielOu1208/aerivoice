import Foundation

@MainActor
final class SonioxRealtimeClient: NSObject, RealtimeTranscribing {
  var onTranscript: ((TranscriptSnapshot) -> Void)?
  var onError: ((Error) -> Void)?

  private var session: URLSession?
  private var task: URLSessionWebSocketTask?
  private var receiveTask: Task<Void, Never>?
  private var assembler = TranscriptAssembler()
  private var snapshot = TranscriptSnapshot()
  private var finishContinuation: CheckedContinuation<String, Error>?
  private var finished = false
  private var generation = UUID()

  func connect(apiKey: String, vocabulary: [String], sessionID: DictationSessionID) async throws {
    cancel()
    let connectionGeneration = UUID()
    generation = connectionGeneration
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 3
    let session = URLSession(configuration: configuration)
    let task = session.webSocketTask(
      with: URL(string: "wss://stt-rt.soniox.com/transcribe-websocket")!)
    self.session = session
    self.task = task
    task.resume()

    let context: [String: Any]? = vocabulary.isEmpty ? nil : ["terms": vocabulary]
    var payload: [String: Any] = [
      "api_key": apiKey,
      "model": "stt-rt-v5",
      "audio_format": "pcm_s16le",
      "sample_rate": 16_000,
      "num_channels": 1,
      "enable_language_identification": true,
      "enable_endpoint_detection": false,
      "client_reference_id": sessionID.rawValue.uuidString,
    ]
    if let context { payload["context"] = context }
    let data = try JSONSerialization.data(withJSONObject: payload)
    let json = String(decoding: data, as: UTF8.self)
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask { try await task.send(.string(json)) }
      group.addTask {
        try await Task.sleep(for: .seconds(3))
        throw AppError.connectionTimeout
      }
      _ = try await group.next()
      group.cancelAll()
    }
    receiveTask = Task { [weak self] in await self?.receiveLoop(generation: connectionGeneration) }
  }

  func send(_ audio: Data) async throws {
    guard let task else { throw AppError.provider("Soniox is not connected.") }
    try await task.send(.data(audio))
  }

  func finish() async throws -> String {
    guard let task else { throw AppError.provider("Soniox is not connected.") }
    let finishGeneration = generation
    return try await withCheckedThrowingContinuation { continuation in
      finishContinuation = continuation
      Task { @MainActor [weak self] in
        do {
          try await task.send(.string(""))
        } catch {
          guard self?.generation == finishGeneration else { return }
          self?.complete(.failure(error))
        }
      }
      Task { @MainActor [weak self] in
        try? await Task.sleep(for: .seconds(3))
        guard let self, self.generation == finishGeneration, self.finishContinuation != nil else {
          return
        }
        self.complete(.failure(AppError.finalizeTimeout))
      }
    }
  }

  func cancel() {
    generation = UUID()
    receiveTask?.cancel()
    receiveTask = nil
    task?.cancel(with: .goingAway, reason: nil)
    task = nil
    session?.invalidateAndCancel()
    session = nil
    if let continuation = finishContinuation {
      continuation.resume(throwing: CancellationError())
      finishContinuation = nil
    }
    assembler = TranscriptAssembler()
    snapshot = TranscriptSnapshot()
    finished = false
  }

  private func receiveLoop(generation connectionGeneration: UUID) async {
    do {
      while !Task.isCancelled, generation == connectionGeneration, let task {
        let message = try await task.receive()
        let data: Data
        switch message {
        case .data(let value): data = value
        case .string(let value): data = Data(value.utf8)
        @unknown default: continue
        }
        try consume(data, generation: connectionGeneration)
      }
    } catch is CancellationError {
    } catch {
      guard generation == connectionGeneration else { return }
      if finishContinuation != nil { complete(.failure(error)) } else { onError?(error) }
    }
  }

  private func consume(_ data: Data, generation connectionGeneration: UUID) throws {
    guard generation == connectionGeneration else { return }
    let response = try JSONDecoder().decode(SonioxResponse.self, from: data)
    if let message = response.errorMessage, !message.isEmpty {
      throw AppError.provider(message)
    }
    snapshot = assembler.consume((response.tokens ?? []).map { ($0.text, $0.isFinal == true) })
    onTranscript?(snapshot)
    if response.finished == true {
      finished = true
      let result = snapshot.displayText.trimmingCharacters(in: .whitespacesAndNewlines)
      complete(result.isEmpty ? .failure(AppError.emptyTranscript) : .success(result))
    }
  }

  private func complete(_ result: Result<String, Error>) {
    guard let continuation = finishContinuation else { return }
    finishContinuation = nil
    task?.cancel(with: .normalClosure, reason: nil)
    task = nil
    continuation.resume(with: result)
  }
}

private struct SonioxResponse: Decodable {
  let tokens: [SonioxToken]?
  let finished: Bool?
  let errorMessage: String?

  enum CodingKeys: String, CodingKey {
    case tokens, finished
    case errorMessage = "error_message"
  }
}

private struct SonioxToken: Decodable {
  let text: String
  let isFinal: Bool?

  enum CodingKeys: String, CodingKey {
    case text
    case isFinal = "is_final"
  }
}

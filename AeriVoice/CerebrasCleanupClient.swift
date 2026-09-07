import Foundation

struct CerebrasCleanupClient: CleaningText {
  private let session: URLSession
  private let warmUpState: CerebrasWarmUpState

  init(session: URLSession = .shared, warmUpInterval: Duration = .seconds(60)) {
    self.session = session
    warmUpState = CerebrasWarmUpState(minimumInterval: warmUpInterval)
  }

  func warmUp(configuration: CleanupConfiguration, apiKey: String) async {
    guard configuration.provider == .cerebras, !apiKey.isEmpty,
      warmUpState.beginWarmUpIfEligible()
    else { return }
    defer { warmUpState.finishWarmUp() }

    var request = URLRequest(url: URL(string: "https://api.cerebras.ai/v1/tcp_warming")!)
    request.timeoutInterval = 1
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    let preparedRequest = request
    let urlSession = session
    do {
      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { _ = try await urlSession.data(for: preparedRequest) }
        group.addTask {
          try await Task.sleep(for: .seconds(1))
          throw URLError(.timedOut)
        }
        _ = try await group.next()
        group.cancelAll()
      }
    } catch {
      // Warming is an optional latency optimization and must never block dictation.
    }
  }

  func clean(
    _ text: String, mode: CleanupMode, configuration: CleanupConfiguration, apiKey: String
  ) async throws -> CleanupTextResult {
    let maxCompletionTokens = try CerebrasTokenBudget.maxCompletionTokens(for: text)
    return try await clean(
      text, mode: mode, configuration: configuration, apiKey: apiKey,
      maxCompletionTokens: maxCompletionTokens)
  }

  private func clean(
    _ text: String, mode: CleanupMode, configuration: CleanupConfiguration, apiKey: String,
    maxCompletionTokens: Int
  ) async throws -> CleanupTextResult {
    guard configuration.provider == .cerebras else {
      throw AppError.provider("The selected cleanup model is not available through Cerebras.")
    }

    var request = URLRequest(url: URL(string: "https://api.cerebras.ai/v1/chat/completions")!)
    request.httpMethod = "POST"
    request.timeoutInterval = 10
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    let encodingStarted = ContinuousClock.now
    request.httpBody = try JSONEncoder().encode(
      CerebrasRequest(
        model: configuration.model.rawValue,
        messages: [
          .init(role: "system", content: CleanupPrompt.system(mode: mode)),
          .init(role: "user", content: text),
        ],
        reasoningEffort: configuration.reasoningEffort.rawValue,
        responseFormat: .init(
          type: "json_schema",
          jsonSchema: .init(
            name: "cleaned_transcript", strict: true,
            schema: .init(
              type: "object", properties: ["text": .init(type: "string")], required: ["text"],
              additionalProperties: false))),
        maxCompletionTokens: maxCompletionTokens
      ))
    let requestEncodingMS = Self.elapsedMilliseconds(since: encodingStarted)

    let preparedRequest = request
    let urlSession = session
    let metricsCollector = CleanupURLSessionMetricsCollector()
    warmUpState.recordRequestStarted()
    let networkStarted = ContinuousClock.now
    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await withThrowingTaskGroup(of: (Data, URLResponse).self) { group in
        group.addTask {
          try await urlSession.data(for: preparedRequest, delegate: metricsCollector)
        }
        group.addTask {
          try await Task.sleep(for: .seconds(10))
          throw URLError(.timedOut)
        }
        guard let first = try await group.next() else { throw URLError(.unknown) }
        group.cancelAll()
        return first
      }
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      let code = (error as? URLError)?.code ?? .unknown
      throw CleanupNetworkError(
        code: code,
        cleanupMetrics: metrics(
          configuration: configuration, response: nil, httpStatus: nil,
          requestEncodingMS: requestEncodingMS,
          networkRequestMS: Self.elapsedMilliseconds(since: networkStarted),
          networkTiming: metricsCollector.snapshot()))
    }
    let networkRequestMS = Self.elapsedMilliseconds(since: networkStarted)
    let networkTiming = metricsCollector.snapshot()
    guard let http = response as? HTTPURLResponse else {
      throw CleanupNetworkError(
        code: .badServerResponse,
        cleanupMetrics: metrics(
          configuration: configuration, response: nil, httpStatus: nil,
          requestEncodingMS: requestEncodingMS, networkRequestMS: networkRequestMS,
          networkTiming: networkTiming))
    }
    guard (200..<300).contains(http.statusCode) else {
      let decodingStarted = ContinuousClock.now
      let decoder = JSONDecoder()
      let envelope = try? decoder.decode(CerebrasErrorEnvelope.self, from: data)
      let metadata = try? decoder.decode(CerebrasResponseMetadata.self, from: data)
      let responseDecodingMS = Self.elapsedMilliseconds(since: decodingStarted)
      throw ProviderHTTPError(
        statusCode: http.statusCode,
        message: Self.errorMessage(
          statusCode: http.statusCode, providerMessage: envelope?.userMessage),
        cleanupMetrics: metrics(
          configuration: configuration, response: metadata, httpStatus: http.statusCode,
          requestEncodingMS: requestEncodingMS, networkRequestMS: networkRequestMS,
          responseDecodingMS: responseDecodingMS, networkTiming: networkTiming))
    }

    let decodingStarted = ContinuousClock.now
    let envelope: CerebrasResponse
    do {
      envelope = try JSONDecoder().decode(CerebrasResponse.self, from: data)
    } catch {
      let metadata = try? JSONDecoder().decode(CerebrasResponseMetadata.self, from: data)
      let responseDecodingMS = Self.elapsedMilliseconds(since: decodingStarted)
      throw ProviderHTTPError(
        statusCode: http.statusCode, message: "Cerebras returned a malformed cleanup.",
        cleanupMetrics: metrics(
          configuration: configuration, response: metadata, httpStatus: http.statusCode,
          requestEncodingMS: requestEncodingMS, networkRequestMS: networkRequestMS,
          responseDecodingMS: responseDecodingMS, networkTiming: networkTiming))
    }
    guard let rawContent = envelope.choices.first?.message.content else {
      let responseDecodingMS = Self.elapsedMilliseconds(since: decodingStarted)
      throw ProviderHTTPError(
        statusCode: http.statusCode, message: "Cerebras returned an empty or malformed cleanup.",
        cleanupMetrics: metrics(
          configuration: configuration, response: envelope.metadata, httpStatus: http.statusCode,
          requestEncodingMS: requestEncodingMS, networkRequestMS: networkRequestMS,
          responseDecodingMS: responseDecodingMS, networkTiming: networkTiming))
    }

    let content = Self.stripThinkingTags(from: rawContent)
    guard let json = content.data(using: .utf8),
      let cleaned = try? JSONDecoder().decode(CerebrasCleanedText.self, from: json),
      !cleaned.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      let responseDecodingMS = Self.elapsedMilliseconds(since: decodingStarted)
      throw ProviderHTTPError(
        statusCode: http.statusCode, message: "Cerebras returned an empty or malformed cleanup.",
        cleanupMetrics: metrics(
          configuration: configuration, response: envelope.metadata, httpStatus: http.statusCode,
          requestEncodingMS: requestEncodingMS, networkRequestMS: networkRequestMS,
          responseDecodingMS: responseDecodingMS, networkTiming: networkTiming))
    }
    let responseDecodingMS = Self.elapsedMilliseconds(since: decodingStarted)
    return CleanupTextResult(
      text: cleaned.text,
      metrics: metrics(
        configuration: configuration, response: envelope.metadata, httpStatus: http.statusCode,
        requestEncodingMS: requestEncodingMS, networkRequestMS: networkRequestMS,
        responseDecodingMS: responseDecodingMS, networkTiming: networkTiming))
  }

  func validate(apiKey: String, model: CleanupModel = .qwen38_27BCerebras) async throws {
    var request = URLRequest(url: URL(string: "https://api.cerebras.ai/v1/models")!)
    request.timeoutInterval = 10
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw AppError.provider("Cerebras returned an invalid response.")
    }
    guard (200..<300).contains(http.statusCode) else {
      let envelope = try? JSONDecoder().decode(CerebrasErrorEnvelope.self, from: data)
      throw AppError.provider(envelope?.userMessage ?? "Cerebras rejected this key.")
    }
    let models = try JSONDecoder().decode(CerebrasModelsResponse.self, from: data)
    guard models.data.contains(where: { $0.id == model.rawValue }) else {
      throw AppError.provider("Cerebras accepted this key, but Qwen 3.8 27B is unavailable.")
    }
    _ = try await clean(
      "Test.", mode: .faithful,
      configuration: CleanupConfiguration(model: model, reasoningEffort: .none), apiKey: apiKey,
      maxCompletionTokens: CerebrasTokenBudget.verificationTokens)
  }

  private static func errorMessage(statusCode: Int, providerMessage: String?) -> String {
    switch statusCode {
    case 413:
      "This request is larger than your Cerebras plan allows. Try a shorter dictation or raise your Cerebras limits."
    case 429:
      "Cerebras is temporarily rate limited. Wait a moment and try again."
    default:
      providerMessage ?? "Cerebras request failed."
    }
  }

  private static func stripThinkingTags(from text: String) -> String {
    var result = text
    while let startRange = result.range(of: "<think>") {
      if let endRange = result.range(of: "</think>", range: startRange.upperBound..<result.endIndex) {
        result.removeSubrange(startRange.lowerBound..<endRange.upperBound)
      } else {
        result.removeSubrange(startRange.lowerBound..<result.endIndex)
        break
      }
    }
    return result.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func metrics(
    configuration: CleanupConfiguration, response: CerebrasResponseMetadata?, httpStatus: Int?,
    requestEncodingMS: Double? = nil, networkRequestMS: Double? = nil,
    responseDecodingMS: Double? = nil, networkTiming: CleanupNetworkTimingMetrics? = nil
  ) -> CleanupRequestMetrics {
    let actualModel = response?.model
    return CleanupRequestMetrics(
      actualModel: actualModel, selectedProvider: "Cerebras",
      selectedProviderModel: actualModel ?? configuration.model.rawValue,
      routingStrategy: "direct", routingAttempt: 1, serviceTier: response?.serviceTier,
      promptTokens: response?.usage?.promptTokens,
      completionTokens: response?.usage?.completionTokens,
      totalTokens: response?.usage?.totalTokens, httpStatus: httpStatus,
      cachedPromptTokens: response?.usage?.promptTokensDetails?.cachedTokens,
      requestEncodingMS: requestEncodingMS, networkRequestMS: networkRequestMS,
      responseDecodingMS: responseDecodingMS,
      providerTiming: response?.timeInfo.map {
        CleanupProviderTimingMetrics(
          queueMS: Self.milliseconds($0.queueTime), promptMS: Self.milliseconds($0.promptTime),
          completionMS: Self.milliseconds($0.completionTime),
          totalMS: Self.milliseconds($0.totalTime))
      },
      networkTiming: networkTiming)
  }

  private static func milliseconds(_ seconds: Double?) -> Double? {
    seconds.map { $0 * 1_000 }
  }

  private static func elapsedMilliseconds(since start: ContinuousClock.Instant) -> Double {
    let components = start.duration(to: ContinuousClock.now).components
    return Double(components.seconds) * 1_000
      + Double(components.attoseconds) / 1_000_000_000_000_000
  }
}

private final class CerebrasWarmUpState: @unchecked Sendable {
  private let lock = NSLock()
  private let minimumInterval: Duration
  private var lastRequestStartedAt: ContinuousClock.Instant?
  private var warmUpInFlight = false

  init(minimumInterval: Duration) { self.minimumInterval = minimumInterval }

  func beginWarmUpIfEligible() -> Bool {
    lock.withLock {
      let now = ContinuousClock.now
      guard !warmUpInFlight else { return false }
      if let lastRequestStartedAt,
        lastRequestStartedAt.duration(to: now) < minimumInterval
      {
        return false
      }
      lastRequestStartedAt = now
      warmUpInFlight = true
      return true
    }
  }

  func finishWarmUp() {
    lock.withLock { warmUpInFlight = false }
  }

  func recordRequestStarted() {
    lock.withLock { lastRequestStartedAt = ContinuousClock.now }
  }
}

enum CerebrasTokenBudget {
  static let verificationTokens = 256
  static let minimumCompletionTokens = 256
  static let maximumCompletionTokens = 4_096
  static let totalTokenLimit = 16_000
  static let requestOverheadTokens = 512

  static func maxCompletionTokens(for text: String) throws -> Int {
    let estimatedTokens = estimatedTokens(for: text)
    let safetyMargin = max(128, (estimatedTokens + 3) / 4)
    let completionTokens = min(
      maximumCompletionTokens,
      max(minimumCompletionTokens, estimatedTokens + safetyMargin))
    guard estimatedTokens + requestOverheadTokens + completionTokens <= totalTokenLimit else {
      throw AppError.provider(
        "This dictation is too long for Cerebras’s current limit. Use OpenRouter or try a shorter dictation."
      )
    }
    return completionTokens
  }

  static func estimatedTokens(for text: String) -> Int {
    var asciiBytes = 0
    var nonASCIIBytes = 0
    for byte in text.utf8 {
      if byte < 0x80 {
        asciiBytes += 1
      } else {
        nonASCIIBytes += 1
      }
    }

    return max(1, (asciiBytes + 3) / 4 + (nonASCIIBytes + 1) / 2)
  }
}

private struct CerebrasRequest: Encodable {
  let model: String
  let messages: [Message]
  let reasoningEffort: String
  let responseFormat: ResponseFormat
  let maxCompletionTokens: Int

  enum CodingKeys: String, CodingKey {
    case model, messages
    case reasoningEffort = "reasoning_effort"
    case responseFormat = "response_format"
    case maxCompletionTokens = "max_completion_tokens"
  }

  struct Message: Encodable {
    let role: String
    let content: String
  }

  struct ResponseFormat: Encodable {
    let type: String
    let jsonSchema: JSONSchema

    enum CodingKeys: String, CodingKey {
      case type
      case jsonSchema = "json_schema"
    }
  }

  struct JSONSchema: Encodable {
    let name: String
    let strict: Bool
    let schema: Schema
  }

  struct Schema: Encodable {
    let type: String
    let properties: [String: Property]
    let required: [String]
    let additionalProperties: Bool
  }

  struct Property: Encodable { let type: String }
}

private struct CerebrasResponse: Decodable {
  let choices: [Choice]
  let model: String?
  let serviceTier: String?
  let usage: CerebrasUsage?
  let timeInfo: CerebrasTimeInfo?

  var metadata: CerebrasResponseMetadata {
    CerebrasResponseMetadata(
      model: model, serviceTier: serviceTier, usage: usage, timeInfo: timeInfo)
  }

  enum CodingKeys: String, CodingKey {
    case choices, model, usage
    case serviceTier = "service_tier"
    case timeInfo = "time_info"
  }

  struct Choice: Decodable { let message: Message }
  struct Message: Decodable { let content: String? }
}

private struct CerebrasResponseMetadata: Decodable {
  let model: String?
  let serviceTier: String?
  let usage: CerebrasUsage?
  let timeInfo: CerebrasTimeInfo?

  enum CodingKeys: String, CodingKey {
    case model, usage
    case serviceTier = "service_tier"
    case timeInfo = "time_info"
  }
}

private struct CerebrasUsage: Decodable {
  let promptTokens: Int?
  let completionTokens: Int?
  let totalTokens: Int?
  let promptTokensDetails: PromptTokensDetails?

  enum CodingKeys: String, CodingKey {
    case promptTokens = "prompt_tokens"
    case completionTokens = "completion_tokens"
    case totalTokens = "total_tokens"
    case promptTokensDetails = "prompt_tokens_details"
  }

  struct PromptTokensDetails: Decodable {
    let cachedTokens: Int?

    enum CodingKeys: String, CodingKey { case cachedTokens = "cached_tokens" }
  }
}

private struct CerebrasTimeInfo: Decodable {
  let queueTime: Double?
  let promptTime: Double?
  let completionTime: Double?
  let totalTime: Double?

  enum CodingKeys: String, CodingKey {
    case queueTime = "queue_time"
    case promptTime = "prompt_time"
    case completionTime = "completion_time"
    case totalTime = "total_time"
  }
}

private final class CleanupURLSessionMetricsCollector: NSObject, URLSessionTaskDelegate,
  @unchecked Sendable
{
  private let lock = NSLock()
  private var taskMetrics: URLSessionTaskMetrics?

  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    didFinishCollecting metrics: URLSessionTaskMetrics
  ) {
    lock.withLock { taskMetrics = metrics }
  }

  func snapshot() -> CleanupNetworkTimingMetrics? {
    lock.withLock {
      guard let transaction = taskMetrics?.transactionMetrics.last else { return nil }
      return CleanupNetworkTimingMetrics(
        connectionReused: transaction.isReusedConnection,
        networkProtocolName: transaction.networkProtocolName,
        dnsMS: Self.durationMS(
          from: transaction.domainLookupStartDate, to: transaction.domainLookupEndDate),
        connectMS: Self.durationMS(
          from: transaction.connectStartDate, to: transaction.connectEndDate),
        secureConnectionMS: Self.durationMS(
          from: transaction.secureConnectionStartDate,
          to: transaction.secureConnectionEndDate),
        requestUploadMS: Self.durationMS(
          from: transaction.requestStartDate, to: transaction.requestEndDate),
        timeToFirstByteMS: Self.durationMS(
          from: transaction.requestStartDate, to: transaction.responseStartDate),
        responseDownloadMS: Self.durationMS(
          from: transaction.responseStartDate, to: transaction.responseEndDate))
    }
  }

  private static func durationMS(from start: Date?, to end: Date?) -> Double? {
    guard let start, let end else { return nil }
    return max(0, end.timeIntervalSince(start) * 1_000)
  }
}

private struct CerebrasCleanedText: Decodable { let text: String }

private struct CerebrasErrorEnvelope: Decodable {
  let message: String?
  let error: ErrorValue?

  var userMessage: String? { error?.message ?? message }

  struct ErrorValue: Decodable { let message: String? }
}

private struct CerebrasModelsResponse: Decodable {
  let data: [Model]
  struct Model: Decodable { let id: String }
}

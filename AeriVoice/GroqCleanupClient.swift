import Foundation

struct GroqCleanupClient: CleaningText {
  private let session: URLSession

  init(session: URLSession = .shared) { self.session = session }

  func clean(
    _ text: String, mode: CleanupMode, configuration: CleanupConfiguration, apiKey: String
  ) async throws -> CleanupTextResult {
    let maxCompletionTokens = try GroqTokenBudget.maxCompletionTokens(for: text)
    return try await clean(
      text, mode: mode, configuration: configuration, apiKey: apiKey,
      maxCompletionTokens: maxCompletionTokens)
  }

  private func clean(
    _ text: String, mode: CleanupMode, configuration: CleanupConfiguration, apiKey: String,
    maxCompletionTokens: Int
  ) async throws -> CleanupTextResult {
    guard configuration.provider == .groq else {
      throw AppError.provider("The selected cleanup model is not available through Groq.")
    }

    var request = URLRequest(url: URL(string: "https://api.groq.com/openai/v1/chat/completions")!)
    request.httpMethod = "POST"
    request.timeoutInterval = 10
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONEncoder().encode(
      GroqRequest(
        model: configuration.model.rawValue,
        messages: [
          .init(role: "system", content: CleanupPrompt.system(mode: mode)),
          .init(role: "user", content: text),
        ],
        reasoningEffort: configuration.reasoningEffort.rawValue,
        reasoningFormat: "hidden",
        responseFormat: .init(
          type: "json_schema",
          jsonSchema: .init(
            name: "cleaned_transcript", strict: true,
            schema: .init(
              type: "object", properties: ["text": .init(type: "string")], required: ["text"],
              additionalProperties: false))),
        maxCompletionTokens: maxCompletionTokens
      ))

    let preparedRequest = request
    let urlSession = session
    let (data, response) = try await withThrowingTaskGroup(of: (Data, URLResponse).self) { group in
      group.addTask { try await urlSession.data(for: preparedRequest) }
      group.addTask {
        try await Task.sleep(for: .seconds(10))
        throw URLError(.timedOut)
      }
      guard let first = try await group.next() else { throw URLError(.unknown) }
      group.cancelAll()
      return first
    }
    guard let http = response as? HTTPURLResponse else {
      throw AppError.provider("Groq returned an invalid response.")
    }
    guard (200..<300).contains(http.statusCode) else {
      let envelope = try? JSONDecoder().decode(GroqErrorEnvelope.self, from: data)
      throw ProviderHTTPError(
        statusCode: http.statusCode,
        message: Self.errorMessage(
          statusCode: http.statusCode, providerMessage: envelope?.error.message),
        cleanupMetrics: metrics(
          configuration: configuration, response: nil, httpStatus: http.statusCode))
    }

    let envelope: GroqResponse
    do {
      envelope = try JSONDecoder().decode(GroqResponse.self, from: data)
    } catch {
      throw ProviderHTTPError(
        statusCode: http.statusCode, message: "Groq returned a malformed cleanup.",
        cleanupMetrics: metrics(
          configuration: configuration, response: nil, httpStatus: http.statusCode))
    }
    guard let content = envelope.choices.first?.message.content,
      let json = content.data(using: .utf8),
      let cleaned = try? JSONDecoder().decode(GroqCleanedText.self, from: json),
      !cleaned.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      throw ProviderHTTPError(
        statusCode: http.statusCode, message: "Groq returned an empty or malformed cleanup.",
        cleanupMetrics: metrics(
          configuration: configuration, response: envelope, httpStatus: http.statusCode))
    }
    return CleanupTextResult(
      text: cleaned.text,
      metrics: metrics(
        configuration: configuration, response: envelope, httpStatus: http.statusCode))
  }

  func validate(apiKey: String, model: CleanupModel = .qwen38_27BGroq) async throws {
    var request = URLRequest(url: URL(string: "https://api.groq.com/openai/v1/models")!)
    request.timeoutInterval = 10
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw AppError.provider("Groq returned an invalid response.")
    }
    guard (200..<300).contains(http.statusCode) else {
      let envelope = try? JSONDecoder().decode(GroqErrorEnvelope.self, from: data)
      throw AppError.provider(envelope?.error.message ?? "Groq rejected this key.")
    }
    let models = try JSONDecoder().decode(GroqModelsResponse.self, from: data)
    guard models.data.contains(where: { $0.id == model.rawValue }) else {
      throw AppError.provider("Groq accepted this key, but Qwen 3.8 27B is unavailable.")
    }
    _ = try await clean(
      "Test.", mode: .faithful,
      configuration: CleanupConfiguration(model: model, reasoningEffort: .none), apiKey: apiKey,
      maxCompletionTokens: GroqTokenBudget.verificationTokens)
  }

  private static func errorMessage(statusCode: Int, providerMessage: String?) -> String {
    switch statusCode {
    case 413:
      "This request is larger than your Groq plan allows. Try a shorter dictation or raise your Groq limits."
    case 429:
      "Groq is temporarily rate limited. Wait a moment and try again."
    default:
      providerMessage ?? "Groq request failed."
    }
  }

  private func metrics(
    configuration: CleanupConfiguration, response: GroqResponse?, httpStatus: Int
  ) -> CleanupRequestMetrics {
    let actualModel = response?.model
    return CleanupRequestMetrics(
      actualModel: actualModel, selectedProvider: "Groq",
      selectedProviderModel: actualModel ?? configuration.model.rawValue,
      routingStrategy: "direct", routingAttempt: 1, serviceTier: response?.serviceTier,
      promptTokens: response?.usage?.promptTokens,
      completionTokens: response?.usage?.completionTokens,
      totalTokens: response?.usage?.totalTokens, httpStatus: httpStatus)
  }
}

enum GroqTokenBudget {
  static let verificationTokens = 256
  static let minimumCompletionTokens = 256
  static let maximumCompletionTokens = 4_096
  static let totalTokenLimit = 8_000
  static let requestOverheadTokens = 512

  static func maxCompletionTokens(for text: String) throws -> Int {
    let estimatedTokens = estimatedTokens(for: text)
    let safetyMargin = max(128, (estimatedTokens + 3) / 4)
    let completionTokens = min(
      maximumCompletionTokens,
      max(minimumCompletionTokens, estimatedTokens + safetyMargin))
    guard estimatedTokens + requestOverheadTokens + completionTokens <= totalTokenLimit else {
      throw AppError.provider(
        "This dictation is too long for Groq’s current experimental limit. Use OpenRouter or try a shorter dictation."
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

private struct GroqRequest: Encodable {
  let model: String
  let messages: [Message]
  let reasoningEffort: String
  let reasoningFormat: String
  let responseFormat: ResponseFormat
  let maxCompletionTokens: Int

  enum CodingKeys: String, CodingKey {
    case model, messages
    case reasoningEffort = "reasoning_effort"
    case reasoningFormat = "reasoning_format"
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

private struct GroqResponse: Decodable {
  let choices: [Choice]
  let model: String?
  let serviceTier: String?
  let usage: Usage?

  enum CodingKeys: String, CodingKey {
    case choices, model, usage
    case serviceTier = "service_tier"
  }

  struct Choice: Decodable { let message: Message }
  struct Message: Decodable { let content: String? }
  struct Usage: Decodable {
    let promptTokens: Int?
    let completionTokens: Int?
    let totalTokens: Int?

    enum CodingKeys: String, CodingKey {
      case promptTokens = "prompt_tokens"
      case completionTokens = "completion_tokens"
      case totalTokens = "total_tokens"
    }
  }
}

private struct GroqCleanedText: Decodable { let text: String }
private struct GroqErrorEnvelope: Decodable {
  let error: ErrorValue
  struct ErrorValue: Decodable { let message: String }
}
private struct GroqModelsResponse: Decodable {
  let data: [Model]
  struct Model: Decodable { let id: String }
}

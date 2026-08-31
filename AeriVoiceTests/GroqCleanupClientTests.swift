import Foundation
import XCTest

@testable import AeriVoice

final class GroqCleanupClientTests: XCTestCase {
  override func setUp() {
    super.setUp()
    GroqURLProtocolStub.handler = nil
  }

  func testCleanupUsesDirectGroqStructuredOutputAndNoneReasoning() async throws {
    GroqURLProtocolStub.handler = { request in
      XCTAssertEqual(request.url?.absoluteString, "https://api.groq.com/openai/v1/chat/completions")
      XCTAssertEqual(request.httpMethod, "POST")
      XCTAssertEqual(request.timeoutInterval, 10)
      XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer key")
      let body = try XCTUnwrap(request.groqBodyData)
      let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
      XCTAssertEqual(json["model"] as? String, "qwen/qwen3.8-27b")
      XCTAssertEqual(json["reasoning_effort"] as? String, "none")
      XCTAssertEqual(json["reasoning_format"] as? String, "hidden")
      XCTAssertEqual(json["max_completion_tokens"] as? Int, 256)
      let responseFormat = try XCTUnwrap(json["response_format"] as? [String: Any])
      XCTAssertEqual(responseFormat["type"] as? String, "json_schema")
      let jsonSchema = try XCTUnwrap(responseFormat["json_schema"] as? [String: Any])
      XCTAssertEqual(jsonSchema["strict"] as? Bool, true)
      let response =
        #"{"model":"qwen/qwen3.8-27b","service_tier":"on_demand","usage":{"prompt_tokens":20,"completion_tokens":4,"total_tokens":24},"choices":[{"message":{"content":"{\"text\":\"Hello, world.\"}"}}]}"#
        .data(using: .utf8)!
      return (
        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
        response
      )
    }

    let result = try await GroqCleanupClient(session: makeSession()).clean(
      "hello world", mode: .faithful,
      configuration: CleanupConfiguration(model: .qwen38_27BGroq, reasoningEffort: .none),
      apiKey: "key")

    XCTAssertEqual(result.text, "Hello, world.")
    XCTAssertEqual(result.metrics.actualModel, "qwen/qwen3.8-27b")
    XCTAssertEqual(result.metrics.selectedProvider, "Groq")
    XCTAssertEqual(result.metrics.selectedProviderModel, "qwen/qwen3.8-27b")
    XCTAssertEqual(result.metrics.routingStrategy, "direct")
    XCTAssertEqual(result.metrics.routingAttempt, 1)
    XCTAssertEqual(result.metrics.serviceTier, "on_demand")
    XCTAssertEqual(result.metrics.totalTokens, 24)
    XCTAssertEqual(result.metrics.httpStatus, 200)
  }

  func testLowReasoningIsEncodedExactly() async throws {
    GroqURLProtocolStub.handler = { request in
      let body = try XCTUnwrap(request.groqBodyData)
      let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
      XCTAssertEqual(json["reasoning_effort"] as? String, "low")
      let response = #"{"choices":[{"message":{"content":"{\"text\":\"Cleaned.\"}"}}]}"#
        .data(using: .utf8)!
      return (
        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
        response
      )
    }

    _ = try await GroqCleanupClient(session: makeSession()).clean(
      "raw", mode: .faithful,
      configuration: CleanupConfiguration(model: .qwen38_27BGroq, reasoningEffort: .low),
      apiKey: "key")
  }

  func testValidationChecksCatalogAndExercisesSelectedModel() async throws {
    var requestCount = 0
    GroqURLProtocolStub.handler = { request in
      requestCount += 1
      let response: Data
      if request.url?.path == "/openai/v1/models" {
        XCTAssertEqual(request.httpMethod, "GET")
        response = #"{"data":[{"id":"qwen/qwen3.8-27b"}]}"#.data(using: .utf8)!
      } else {
        XCTAssertEqual(request.url?.path, "/openai/v1/chat/completions")
        let body = try XCTUnwrap(request.groqBodyData)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "qwen/qwen3.8-27b")
        XCTAssertEqual(json["reasoning_effort"] as? String, "none")
        XCTAssertEqual(json["max_completion_tokens"] as? Int, 256)
        response = #"{"choices":[{"message":{"content":"{\"text\":\"Test.\"}"}}]}"#
          .data(using: .utf8)!
      }
      return (
        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
        response
      )
    }

    try await GroqCleanupClient(session: makeSession()).validate(apiKey: "key")

    XCTAssertEqual(requestCount, 2)
  }

  func testValidationRejectsKeyWhenModelPermissionBlocksCleanup() async {
    GroqURLProtocolStub.handler = { request in
      if request.url?.path == "/openai/v1/models" {
        return (
          HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
          #"{"data":[{"id":"qwen/qwen3.8-27b"}]}"#.data(using: .utf8)!
        )
      }
      return (
        HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!,
        #"{"error":{"message":"Model blocked by project permissions"}}"#.data(using: .utf8)!
      )
    }

    do {
      try await GroqCleanupClient(session: makeSession()).validate(apiKey: "key")
      XCTFail("Expected model permission failure")
    } catch {
      XCTAssertEqual((error as? ProviderHTTPError)?.statusCode, 403)
      XCTAssertTrue(error.localizedDescription.contains("Model blocked"))
    }
  }

  func testProviderErrorIncludesGroqMetrics() async {
    GroqURLProtocolStub.handler = { request in
      let response = #"{"error":{"message":"Rate limited"}}"#.data(using: .utf8)!
      return (
        HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: nil, headerFields: nil)!,
        response
      )
    }

    do {
      _ = try await GroqCleanupClient(session: makeSession()).clean(
        "raw", mode: .faithful,
        configuration: CleanupConfiguration(model: .qwen38_27BGroq, reasoningEffort: .none),
        apiKey: "key")
      XCTFail("Expected 429 to fail")
    } catch {
      XCTAssertEqual(
        error.localizedDescription, "Groq is temporarily rate limited. Wait a moment and try again."
      )
      XCTAssertEqual((error as? ProviderHTTPError)?.statusCode, 429)
      XCTAssertEqual((error as? ProviderHTTPError)?.cleanupMetrics?.selectedProvider, "Groq")
      XCTAssertEqual(
        (error as? ProviderHTTPError)?.cleanupMetrics?.selectedProviderModel,
        "qwen/qwen3.8-27b")
    }
  }

  func testTokenBudgetGrowsWithInputAndStaysWithinTotalLimit() throws {
    XCTAssertEqual(try GroqTokenBudget.maxCompletionTokens(for: "Test."), 256)
    XCTAssertEqual(
      try GroqTokenBudget.maxCompletionTokens(for: String(repeating: "a", count: 8_000)), 2_500)
    XCTAssertEqual(
      try GroqTokenBudget.maxCompletionTokens(for: String(repeating: "é", count: 1_000)), 1_250)

    let text = String(repeating: "a", count: 12_000)
    let completionTokens = try GroqTokenBudget.maxCompletionTokens(for: text)
    XCTAssertLessThanOrEqual(
      GroqTokenBudget.estimatedTokens(for: text) + GroqTokenBudget.requestOverheadTokens
        + completionTokens,
      GroqTokenBudget.totalTokenLimit)
  }

  func testTokenBudgetRejectsDictationThatCannotFitInputAndOutput() {
    XCTAssertThrowsError(
      try GroqTokenBudget.maxCompletionTokens(for: String(repeating: "a", count: 20_000))
    ) { error in
      XCTAssertEqual(
        error.localizedDescription,
        "This dictation is too long for Groq’s current experimental limit. Use OpenRouter or try a shorter dictation."
      )
    }
  }

  func testOversizedRequestUsesConciseActionableError() async {
    GroqURLProtocolStub.handler = { request in
      let response = #"{"error":{"message":"Request too large for this organization and model"}}"#
        .data(using: .utf8)!
      return (
        HTTPURLResponse(url: request.url!, statusCode: 413, httpVersion: nil, headerFields: nil)!,
        response
      )
    }

    do {
      _ = try await GroqCleanupClient(session: makeSession()).clean(
        "raw", mode: .faithful,
        configuration: CleanupConfiguration(model: .qwen38_27BGroq, reasoningEffort: .none),
        apiKey: "key")
      XCTFail("Expected 413 to fail")
    } catch {
      XCTAssertEqual(
        error.localizedDescription,
        "This request is larger than your Groq plan allows. Try a shorter dictation or raise your Groq limits."
      )
    }
  }

  func testMalformedSuccessIncludesKnownGroqAttemptMetrics() async {
    GroqURLProtocolStub.handler = { request in
      let response = #"{"model":"qwen/qwen3.8-27b","choices":[]}"#.data(using: .utf8)!
      return (
        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
        response
      )
    }

    do {
      _ = try await GroqCleanupClient(session: makeSession()).clean(
        "raw", mode: .faithful,
        configuration: CleanupConfiguration(model: .qwen38_27BGroq, reasoningEffort: .none),
        apiKey: "key")
      XCTFail("Expected malformed cleanup to fail")
    } catch {
      let providerError = error as? ProviderHTTPError
      XCTAssertEqual(providerError?.statusCode, 200)
      XCTAssertEqual(providerError?.cleanupMetrics?.actualModel, "qwen/qwen3.8-27b")
      XCTAssertEqual(providerError?.cleanupMetrics?.selectedProvider, "Groq")
      XCTAssertEqual(providerError?.cleanupMetrics?.routingStrategy, "direct")
      XCTAssertEqual(providerError?.cleanupMetrics?.routingAttempt, 1)
    }
  }

  func testCleanupRouterUsesProviderOwnedBySelectedModel() async throws {
    let expectations: [(CleanupConfiguration, String)] = [
      (
        CleanupConfiguration(model: .gemini37Flash, reasoningEffort: .low),
        "openrouter.ai"
      ),
      (
        CleanupConfiguration(model: .qwen38_27BGroq, reasoningEffort: .none),
        "api.groq.com"
      ),
    ]

    for (configuration, expectedHost) in expectations {
      let session = makeSession()
      GroqURLProtocolStub.handler = { request in
        XCTAssertEqual(request.url?.host, expectedHost)
        let response = #"{"choices":[{"message":{"content":"{\"text\":\"Cleaned.\"}"}}]}"#
          .data(using: .utf8)!
        return (
          HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
          response
        )
      }
      let router = CleanupClientRouter(
        openRouter: OpenRouterCleanupClient(session: session),
        groq: GroqCleanupClient(session: session))

      let result = try await router.clean(
        "raw", mode: .faithful, configuration: configuration, apiKey: "key")

      XCTAssertEqual(result.text, "Cleaned.")
    }
  }

  private func makeSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [GroqURLProtocolStub.self]
    return URLSession(configuration: configuration)
  }
}

extension URLRequest {
  fileprivate var groqBodyData: Data? {
    if let httpBody { return httpBody }
    guard let stream = httpBodyStream else { return nil }
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while stream.hasBytesAvailable {
      let count = stream.read(&buffer, maxLength: buffer.count)
      guard count > 0 else { break }
      data.append(buffer, count: count)
    }
    return data
  }
}

private final class GroqURLProtocolStub: URLProtocol, @unchecked Sendable {
  nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    do {
      let result = try Self.handler!(request)
      client?.urlProtocol(self, didReceive: result.0, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: result.1)
      client?.urlProtocolDidFinishLoading(self)
    } catch {
      client?.urlProtocol(self, didFailWithError: error)
    }
  }
  override func stopLoading() {}
}

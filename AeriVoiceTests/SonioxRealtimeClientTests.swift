import Foundation
import XCTest

@testable import AeriVoice

@MainActor
final class SonioxRealtimeClientTests: XCTestCase {
  private func configurationMessage(language: String?) async throws -> [String: Any] {
    let socket = SonioxTestSocket()
    let client = SonioxRealtimeClient(makeTransport: { _ in socket })
    try await client.connect(
      configuration: TranscriptionConfiguration(provider: .soniox, language: language),
      apiKey: "test-key", vocabulary: ["AeriVoice"], sessionID: DictationSessionID())
    client.cancel()
    let text = try XCTUnwrap(socket.sentText.first)
    return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
  }

  func testAutoDetectSendsNoLanguageHints() async throws {
    let message = try await configurationMessage(language: nil)
    XCTAssertEqual(message["model"] as? String, "stt-rt-v5")
    XCTAssertEqual(message["enable_language_identification"] as? Bool, true)
    XCTAssertNil(message["language_hints"])
    XCTAssertNil(message["language_hints_strict"])
  }

  func testAChosenLanguageRestrictsRecognitionToIt() async throws {
    let message = try await configurationMessage(language: "en")
    XCTAssertEqual(message["language_hints"] as? [String], ["en"])
    XCTAssertEqual(message["language_hints_strict"] as? Bool, true)
    XCTAssertEqual(message["enable_language_identification"] as? Bool, true)
    XCTAssertEqual((message["context"] as? [String: [String]])?["terms"], ["AeriVoice"])
  }
}

@MainActor
private final class SonioxTestSocket: RealtimeWebSocketTransport {
  private(set) var sentText: [String] = []
  private var cancelled = false
  private var waiter: CheckedContinuation<URLSessionWebSocketTask.Message, Error>?

  func send(_ message: URLSessionWebSocketTask.Message) async throws {
    if case .string(let text) = message { sentText.append(text) }
  }

  func receive() async throws -> URLSessionWebSocketTask.Message {
    if cancelled { throw CancellationError() }
    return try await withCheckedThrowingContinuation { waiter = $0 }
  }

  func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
    cancelled = true
    let pending = waiter
    waiter = nil
    pending?.resume(throwing: CancellationError())
  }
}

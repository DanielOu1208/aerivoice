import Foundation
import XCTest

@testable import AeriVoice

final class OpenRouterCleanupClientTests: XCTestCase {
  override func setUp() {
    super.setUp()
    URLProtocolStub.handler = nil
  }

  func testCleanupUsesExactModelLatencyZDRAndLowReasoning() async throws {
    URLProtocolStub.handler = { request in
      let body = try XCTUnwrap(request.bodyData)
      let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
      XCTAssertEqual(json["model"] as? String, "google/gemini-3.7-flash")
      let reasoning = try XCTUnwrap(json["reasoning"] as? [String: Any])
      XCTAssertEqual(reasoning["effort"] as? String, "low")
      XCTAssertEqual(reasoning["exclude"] as? Bool, true)
      let provider = try XCTUnwrap(json["provider"] as? [String: Any])
      XCTAssertEqual(provider["sort"] as? String, "latency")
      XCTAssertEqual(provider["zdr"] as? Bool, true)
      XCTAssertEqual(provider["allow_fallbacks"] as? Bool, true)
      XCTAssertEqual(provider["require_parameters"] as? Bool, true)
      XCTAssertNil(json["temperature"])
      let response = #"{"choices":[{"message":{"content":"{\"text\":\"Hello, world.\"}"}}]}"#.data(
        using: .utf8)!
      return (
        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
        response
      )
    }
    let result = try await OpenRouterCleanupClient(session: makeSession()).clean(
      "hello world", mode: .faithful, apiKey: "key")
    XCTAssertEqual(result, "Hello, world.")
  }

  func testMalformedCleanupFails() async {
    URLProtocolStub.handler = { request in
      let response = #"{"choices":[{"message":{"content":"not-json"}}]}"#.data(using: .utf8)!
      return (
        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
        response
      )
    }
    do {
      _ = try await OpenRouterCleanupClient(session: makeSession()).clean(
        "raw", mode: .faithful, apiKey: "key")
      XCTFail("Expected malformed response to fail")
    } catch {}
  }

  func testProviderErrorIncludesMessage() async {
    URLProtocolStub.handler = { request in
      let response = #"{"error":{"message":"Rate limited"}}"#.data(using: .utf8)!
      return (
        HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: nil, headerFields: nil)!,
        response
      )
    }
    do {
      _ = try await OpenRouterCleanupClient(session: makeSession()).clean(
        "raw", mode: .faithful, apiKey: "key")
      XCTFail("Expected 429 to fail")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("Rate limited"))
    }
  }

  private func makeSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [URLProtocolStub.self]
    return URLSession(configuration: configuration)
  }
}

extension URLRequest {
  fileprivate var bodyData: Data? {
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

private final class URLProtocolStub: URLProtocol, @unchecked Sendable {
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

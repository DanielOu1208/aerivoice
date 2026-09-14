import Foundation
import XCTest

@testable import AeriVoice

final class AppNetworkPolicyTests: XCTestCase, @unchecked Sendable {
  func testOfflineRejectsWorkBeforeItStartsAndCanReturnOnline() async throws {
    let policy = AppNetworkPolicy(offline: true)
    do {
      _ = try await policy.perform {
        XCTFail("Offline request started")
        return 1
      }
      XCTFail("Offline request succeeded")
    } catch is AppNetworkPolicy.PolicyError {}
    await policy.setOffline(false)
    let value = try await policy.perform { 42 }
    XCTAssertEqual(value, 42)
  }

  func testOfflineCancelsExistingRequestAndRejectsLateSuccess() async throws {
    let policy = AppNetworkPolicy()
    let started = expectation(description: "request started")
    let request = Task {
      try await policy.perform {
        started.fulfill()
        // Emulate a service that catches cancellation and still returns a response.
        try? await Task.sleep(for: .seconds(30))
        return "late response"
      }
    }
    await fulfillment(of: [started], timeout: 2)
    await policy.setOffline(true)
    do {
      _ = try await request.value
      XCTFail("Late response escaped Offline mode")
    } catch {}
    XCTAssertTrue(policy.isOffline)
  }

  func testCallerCancellationReachesTheUnderlyingOperation() async throws {
    let policy = AppNetworkPolicy()
    let started = expectation(description: "request started")
    let stopped = expectation(description: "request cancelled")
    let request = Task {
      try await policy.perform {
        started.fulfill()
        defer { stopped.fulfill() }
        try await Task.sleep(for: .seconds(30))
        return 1
      }
    }
    await fulfillment(of: [started], timeout: 2)
    request.cancel()
    do {
      _ = try await request.value
      XCTFail("Cancelled request succeeded")
    } catch {}
    await fulfillment(of: [stopped], timeout: 2)
  }

  func testEnteringOfflineCancelsARealURLSessionRequest() async throws {
    let policy = AppNetworkPolicy()
    let started = expectation(description: "URLSession started")
    let stopped = expectation(description: "URLSession cancelled")
    let id = UUID().uuidString
    OfflinePolicyURLProtocol.install(id: id, started: started, stopped: stopped)
    defer { OfflinePolicyURLProtocol.remove(id: id) }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [OfflinePolicyURLProtocol.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let request = URLRequest(url: URL(string: "https://policy-test.invalid/\(id)")!)
    let work = Task { try await policy.data(for: request, session: session) }
    await fulfillment(of: [started], timeout: 2)
    await policy.setOffline(true)
    do {
      _ = try await work.value
      XCTFail("Cancelled HTTP request succeeded")
    } catch {}
    await fulfillment(of: [stopped], timeout: 2)
  }

  func testOfflineHTTPAndSocketCannotStart() async {
    let policy = AppNetworkPolicy(offline: true)
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    do {
      _ = try await policy.data(
        for: URLRequest(url: URL(string: "https://invalid.example")!), session: session)
      XCTFail("Offline HTTP request succeeded")
    } catch is AppNetworkPolicy.PolicyError {} catch { XCTFail("Unexpected error: \(error)") }
    let socket = session.webSocketTask(with: URL(string: "wss://invalid.example")!)
    policy.resume(socket)
    XCTAssertNotEqual(socket.state, .running)
  }
}

private final class OfflinePolicyURLProtocol: URLProtocol, @unchecked Sendable {
  private static let lock = NSLock()
  nonisolated(unsafe) private static var requests:
    [String: (XCTestExpectation, XCTestExpectation)] = [:]
  static func install(id: String, started: XCTestExpectation, stopped: XCTestExpectation) {
    lock.withLock { requests[id] = (started, stopped) }
  }
  static func remove(id: String) { _ = lock.withLock { requests.removeValue(forKey: id) } }
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    Self.lock.withLock { Self.requests[request.url!.lastPathComponent]?.0.fulfill() }
  }
  override func stopLoading() {
    Self.lock.withLock { Self.requests[request.url!.lastPathComponent]?.1.fulfill() }
  }
}

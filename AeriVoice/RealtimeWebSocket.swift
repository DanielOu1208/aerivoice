import Foundation

/// One WebSocket to a transcription provider. Each provider's client speaks its own protocol
/// over it; tests and the eval harness put a scripted socket in its place.
@MainActor
protocol RealtimeWebSocketTransport: AnyObject, Sendable {
  /// Starts the handshake without waiting for it; the first send or receive waits instead.
  func resume()
  /// Starts the handshake and returns once the server has accepted the socket.
  func open() async throws
  func send(_ message: URLSessionWebSocketTask.Message) async throws
  func receive() async throws -> URLSessionWebSocketTask.Message
  func ping() async throws
  func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?)
  /// Releases a URL session that was kept after `cancel`.
  func invalidate()
}

extension RealtimeWebSocketTransport {
  // A scripted socket implements only what its provider's client calls.
  func resume() {}
  func open() async throws { resume() }
  func ping() async throws {}
  func invalidate() {}
}

/// Why a socket operation failed, for a provider's client to turn into its own error.
struct RealtimeSocketFailure {
  /// What the failed call threw.
  let thrown: Error
  /// What the socket's task ended with, when it has ended.
  let completion: Error?
  /// The HTTP status of a refused handshake.
  let httpStatus: Int?
  /// The WebSocket close code, when the socket closed with one.
  let closeCode: Int?
}

/// One monotonic clock for pacing audio and timing a connection's life; tests substitute a
/// manual one.
@MainActor
struct RealtimeClock {
  var now: () -> ContinuousClock.Instant
  var sleep: (ContinuousClock.Instant) async throws -> Void

  static var continuous: Self {
    Self(now: { ContinuousClock.now }, sleep: { try await ContinuousClock().sleep(until: $0) })
  }
}

@MainActor
final class URLSessionRealtimeTransport: NSObject, RealtimeWebSocketTransport,
  URLSessionWebSocketDelegate
{
  private var session: URLSession!
  private var task: URLSessionWebSocketTask?
  private let keepsSession: Bool
  private let makeError: (RealtimeSocketFailure) -> Error
  private var openContinuation: CheckedContinuation<Void, Error>?
  private var end: (closeCode: Int?, error: Error?)?
  private var endWaiters: [CheckedContinuation<Void, Never>] = []

  /// - Parameters:
  ///   - keepsSession: `cancel` closes the socket and keeps the URL session until
  ///     `invalidate`, as Soniox does between dictations.
  ///   - makeError: the provider's error for a failure.
  convenience init(
    url: URL, keepsSession: Bool = false, makeError: @escaping (RealtimeSocketFailure) -> Error
  ) {
    self.init(keepsSession: keepsSession, makeError: makeError) { $0.webSocketTask(with: url) }
  }

  /// - Parameter makeError: the provider's error for a failure. A URL that carries dictionary
  ///   terms must not survive in it: Foundation keeps the URL in the errors it throws.
  convenience init(request: URLRequest, makeError: @escaping (RealtimeSocketFailure) -> Error) {
    self.init(keepsSession: false, makeError: makeError) { $0.webSocketTask(with: request) }
  }

  private init(
    keepsSession: Bool, makeError: @escaping (RealtimeSocketFailure) -> Error,
    makeTask: (URLSession) -> URLSessionWebSocketTask
  ) {
    self.keepsSession = keepsSession
    self.makeError = makeError
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 3
    super.init()
    session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    task = makeTask(session)
  }

  func resume() {
    if let task { AppNetworkPolicy.shared.resume(task) }
  }

  func open() async throws {
    guard let task else { throw CancellationError() }
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      openContinuation = continuation
      AppNetworkPolicy.shared.resume(task)
    }
  }

  func send(_ message: URLSessionWebSocketTask.Message) async throws {
    guard let task else { throw CancellationError() }
    do { try await task.send(message) } catch { throw await failure(error, on: task) }
  }

  func receive() async throws -> URLSessionWebSocketTask.Message {
    guard let task else { throw CancellationError() }
    do { return try await task.receive() } catch { throw await failure(error, on: task) }
  }

  func ping() async throws {
    guard let task else { throw CancellationError() }
    do {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        task.sendPing { error in
          if let error { continuation.resume(throwing: error) } else { continuation.resume() }
        }
      }
    } catch {
      // A ping that fails says only that the socket is dead.
      throw makeError(
        RealtimeSocketFailure(thrown: error, completion: nil, httpStatus: nil, closeCode: nil))
    }
  }

  func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
    if let task {
      AppNetworkPolicy.shared.forget(task)
      task.cancel(with: closeCode, reason: reason)
    }
    if keepsSession {
      // Keeping the session must not keep its closed socket.
      task = nil
    } else {
      session.invalidateAndCancel()
    }
    finishOpen(.failure(CancellationError()))
    finishEnd(closeCode: nil, error: nil)
  }

  func invalidate() { session.invalidateAndCancel() }

  /// The close code and a refused handshake's status reach the delegate around the time the
  /// pending call fails, and they are what tells a finished session from a dropped one.
  private func failure(_ thrown: Error, on task: URLSessionWebSocketTask) async -> Error {
    await waitForEnd()
    return makeError(failure(thrown, completion: end?.error, on: task))
  }

  private func failure(
    _ thrown: Error, completion: Error?, on task: URLSessionWebSocketTask
  ) -> RealtimeSocketFailure {
    let status = (task.response as? HTTPURLResponse)?.statusCode
    let closeCode = end?.closeCode ?? (task.closeCode == .invalid ? nil : task.closeCode.rawValue)
    return RealtimeSocketFailure(
      thrown: thrown, completion: completion, httpStatus: status == 101 ? nil : status,
      closeCode: closeCode)
  }

  private func waitForEnd() async {
    guard end == nil else { return }
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      endWaiters.append(continuation)
      // A socket whose end is never reported must not hold its caller.
      Task { @MainActor [weak self] in
        try? await Task.sleep(for: .seconds(1))
        self?.resumeEndWaiters()
      }
    }
  }

  private func finishEnd(closeCode: Int?, error: Error?) {
    if end == nil { end = (closeCode, error) }
    resumeEndWaiters()
  }

  private func resumeEndWaiters() {
    let waiters = endWaiters
    endWaiters.removeAll()
    waiters.forEach { $0.resume() }
  }

  private func finishOpen(_ result: Result<Void, Error>) {
    guard let continuation = openContinuation else { return }
    openContinuation = nil
    continuation.resume(with: result)
  }

  nonisolated func urlSession(
    _ session: URLSession, webSocketTask: URLSessionWebSocketTask,
    didOpenWithProtocol protocol: String?
  ) {
    Task { @MainActor [weak self] in self?.finishOpen(.success(())) }
  }

  nonisolated func urlSession(
    _ session: URLSession, webSocketTask: URLSessionWebSocketTask,
    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?
  ) {
    let code = closeCode.rawValue
    Task { @MainActor [weak self] in self?.ended(webSocketTask, closeCode: code, error: nil) }
  }

  nonisolated func urlSession(
    _ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?
  ) {
    Task { @MainActor [weak self] in
      guard let webSocketTask = task as? URLSessionWebSocketTask else { return }
      let code = webSocketTask.closeCode
      self?.ended(webSocketTask, closeCode: code == .invalid ? nil : code.rawValue, error: error)
    }
  }

  private func ended(_ task: URLSessionWebSocketTask, closeCode: Int?, error: Error?) {
    AppNetworkPolicy.shared.forget(task)
    finishEnd(closeCode: closeCode, error: error)
    if openContinuation != nil {
      // A refused handshake ends here, with the HTTP status on the task's response.
      let thrown = error ?? URLError(.networkConnectionLost)
      finishOpen(.failure(makeError(failure(thrown, completion: error, on: task))))
    }
    if !keepsSession { session.finishTasksAndInvalidate() }
  }
}

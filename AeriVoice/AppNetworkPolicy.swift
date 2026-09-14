import Foundation

/// Owns app-initiated network work so entering Offline mode also cancels requests
/// which started before the switch. It does not control macOS system services.
final class AppNetworkPolicy: @unchecked Sendable {
  static let shared = AppNetworkPolicy(offline: UserDefaults.standard.bool(forKey: "offlineMode"))

  enum PolicyError: LocalizedError {
    case offline
    var errorDescription: String? { "Turn off Offline mode to connect to the internet." }
  }

  private struct Operation {
    let cancel: @Sendable () -> Void
    let wait: @Sendable () async -> Void
  }
  private let lock = NSLock()
  private var offline: Bool
  private var generation = UUID()
  private var operations: [UUID: Operation] = [:]
  private var sockets: [ObjectIdentifier: URLSessionWebSocketTask] = [:]

  init(offline: Bool = false) { self.offline = offline }
  var isOffline: Bool { lock.withLock { offline } }

  func checkAllowed() throws {
    try lock.withLock { if offline { throw PolicyError.offline } }
  }

  func setOffline(_ value: Bool) async {
    let pending: [Operation] = lock.withLock {
      offline = value
      generation = UUID()
      guard value else { return [] }
      for socket in sockets.values { socket.cancel() }
      sockets.removeAll()
      let pending = Array(operations.values)
      pending.forEach { $0.cancel() }
      return pending
    }
    for operation in pending { await operation.wait() }
  }

  func perform<Value: Sendable>(
    _ body: @escaping @Sendable () async throws -> Value
  ) async throws -> Value {
    let id = UUID()
    let (task, startedGeneration): (Task<Value, Error>, UUID) = try lock.withLock {
      guard !offline else { throw PolicyError.offline }
      let task = Task {
        try Task.checkCancellation()
        return try await body()
      }
      operations[id] = Operation(cancel: { task.cancel() }, wait: { _ = await task.result })
      return (task, generation)
    }
    defer { _ = lock.withLock { operations.removeValue(forKey: id) } }
    return try await withTaskCancellationHandler {
      let value = try await task.value
      try Task.checkCancellation()
      try lock.withLock {
        guard !offline, generation == startedGeneration else { throw PolicyError.offline }
      }
      return value
    } onCancel: {
      task.cancel()
    }
  }

  func data(
    for request: URLRequest, session: URLSession = .shared,
    delegate: (any URLSessionTaskDelegate)? = nil
  ) async throws -> (Data, URLResponse) {
    try await perform { try await session.data(for: request, delegate: delegate) }
  }

  func download(from url: URL, delegate: (any URLSessionTaskDelegate)? = nil) async throws -> (
    URL, URLResponse
  ) {
    try await perform { try await URLSession.shared.download(from: url, delegate: delegate) }
  }

  /// Creation is harmless; resume is serialized with the offline transition.
  func resume(_ socket: URLSessionWebSocketTask) {
    lock.withLock {
      guard !offline else {
        socket.cancel()
        return
      }
      sockets[ObjectIdentifier(socket)] = socket
      socket.resume()
    }
  }

  func forget(_ socket: URLSessionWebSocketTask) {
    _ = lock.withLock { sockets.removeValue(forKey: ObjectIdentifier(socket)) }
  }
}

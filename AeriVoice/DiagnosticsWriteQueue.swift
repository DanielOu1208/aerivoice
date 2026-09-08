import Foundation
import OSLog

/// One ordering boundary for interaction and runtime writes, opt-out, and clearing.
@MainActor
final class DiagnosticsWriteQueue {
  let store: LatencyBenchmarkStore
  private var tail: Task<Void, Never>?
  private let state = State()
  private let logger = Logger(subsystem: "com.danielou.AeriVoice", category: "Diagnostics")

  init(directoryURL: URL) { store = LatencyBenchmarkStore(directoryURL: directoryURL) }

  var generation: UUID { state.generation }
  var droppedWrites: Int { state.droppedWrites }

  func revokePendingCollection() { state.revoke() }

  @discardableResult
  func enqueue(
    control: Bool = false,
    critical: Bool = false,
    _ operation: @escaping @Sendable (LatencyBenchmarkStore) async throws -> Void
  ) -> Bool {
    guard state.reserve(control: control || critical) else { return false }
    let generation = state.generation
    let previous = tail
    let store = store
    let state = state
    let logger = logger
    tail = Task.detached(priority: .utility) {
      defer { state.complete() }
      await previous?.value
      guard control || state.generation == generation else { return }
      do { try await operation(store) }
      catch { logger.error("Diagnostics persistence failed") }
    }
    return true
  }

  func flush() async { await tail?.value }

  @discardableResult
  func flushBeforeTermination(timeout: TimeInterval = 2) -> Bool {
    guard let tail else { return true }
    let semaphore = DispatchSemaphore(value: 0)
    Task.detached {
      await tail.value
      semaphore.signal()
    }
    return semaphore.wait(timeout: .now() + timeout) == .success
  }

  private final class State: @unchecked Sendable {
    private let lock = NSLock()
    private var token = UUID()
    private var pending = 0
    private var dropped = 0
    var generation: UUID { lock.withLock { token } }
    var droppedWrites: Int { lock.withLock { dropped } }
    func revoke() { lock.withLock { token = UUID() } }
    func reserve(control: Bool) -> Bool {
      lock.withLock {
        guard control || pending < 128 else { dropped += 1; return false }
        pending += 1
        return true
      }
    }
    func complete() { lock.withLock { pending -= 1 } }
  }
}

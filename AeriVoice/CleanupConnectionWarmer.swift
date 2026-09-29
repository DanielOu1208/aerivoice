import Foundation

/// Opens the provider connection at hotkey-down so the cleanup request after stop reuses it.
/// Skipped when a request started recently, since that connection is likely still open.
final class CleanupConnectionWarmer: @unchecked Sendable {
  private let lock = NSLock()
  private let minimumInterval: Duration
  private var lastRequestStartedAt: ContinuousClock.Instant?
  private var warmUpInFlight = false

  init(minimumInterval: Duration = .seconds(60)) { self.minimumInterval = minimumInterval }

  func warm(_ request: URLRequest, session: URLSession) async {
    guard beginWarmUpIfEligible() else { return }
    defer { finishWarmUp() }
    var request = request
    request.timeoutInterval = 1
    let preparedRequest = request
    do {
      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { _ = try await AppNetworkPolicy.shared.data(for: preparedRequest, session: session) }
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

  func recordRequestStarted() {
    lock.withLock { lastRequestStartedAt = ContinuousClock.now }
  }

  private func beginWarmUpIfEligible() -> Bool {
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

  private func finishWarmUp() {
    lock.withLock { warmUpInFlight = false }
  }
}

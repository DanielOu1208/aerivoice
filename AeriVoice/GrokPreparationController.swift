import Foundation

/// App lifecycle eligibility for audio-free preparation. The client owns expiry and renewal;
/// a periodic check keeps a connection ready while the app was recently used.
@MainActor
final class GrokPreparationController {
  private let eligible: () -> Bool
  private let prepare: () async -> Bool
  private let discard: () -> Void
  private let refreshInterval: Duration?
  private let keepWarmWindow: Duration
  private var lastActivity = ContinuousClock.now
  private var task: Task<Void, Never>?
  private var refreshTask: Task<Void, Never>?
  private var generation = UUID()
  private var sleeping = false
  private var locked: Bool
  private var stopped = false
  var isEligible: Bool { !stopped && !sleeping && !locked && eligible() }

  init(
    initiallyLocked: Bool, eligible: @escaping () -> Bool,
    prepare: @escaping () async -> Bool, discard: @escaping () -> Void,
    refreshInterval: Duration? = nil, keepWarmWindow: Duration = .seconds(1_800)
  ) {
    locked = initiallyLocked
    self.eligible = eligible
    self.prepare = prepare
    self.discard = discard
    self.refreshInterval = refreshInterval
    self.keepWarmWindow = keepWarmWindow
  }

  /// Called for launch, wake, unlock, settings changes, and finished dictations.
  func request() {
    lastActivity = .now
    requestPreparation()
  }

  private func requestPreparation() {
    guard isEligible else { invalidate(); return }
    guard task == nil else { return }
    let id = generation
    task = Task { [weak self] in
      guard let self, !Task.isCancelled else { return }
      let prepared = await self.prepare()
      guard self.generation == id else { return }
      self.task = nil
      if prepared { self.scheduleRefresh(generation: id) }
    }
  }

  /// A fixed cadence: later requests must not push the next check past the slot's expiry.
  private func scheduleRefresh(generation id: UUID) {
    guard let refreshInterval, refreshTask == nil else { return }
    refreshTask = Task { [weak self] in
      do { try await Task.sleep(for: refreshInterval) } catch { return }
      guard let self, self.generation == id else { return }
      self.refreshTask = nil
      guard self.lastActivity.duration(to: .now) < self.keepWarmWindow else { return }
      self.requestPreparation()
    }
  }

  func invalidate() {
    generation = UUID()
    task?.cancel()
    task = nil
    refreshTask?.cancel()
    refreshTask = nil
    discard()
  }

  func setSleeping(_ value: Bool) {
    sleeping = value
    if value { invalidate() } else { request() }
  }

  func setLocked(_ value: Bool) {
    locked = value
    if value { invalidate() } else { request() }
  }

  func stop() {
    stopped = true
    invalidate()
  }
}

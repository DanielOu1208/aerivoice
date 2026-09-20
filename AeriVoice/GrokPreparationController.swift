import Foundation

/// App lifecycle eligibility for audio-free preparation. The client owns expiry.
@MainActor
final class GrokPreparationController {
  private let eligible: () -> Bool
  private let prepare: () async -> Bool
  private let discard: () -> Void
  private var task: Task<Void, Never>?
  private var generation = UUID()
  private var sleeping = false
  private var locked: Bool
  private var stopped = false
  var isEligible: Bool { !stopped && !sleeping && !locked && eligible() }

  init(
    initiallyLocked: Bool, eligible: @escaping () -> Bool,
    prepare: @escaping () async -> Bool, discard: @escaping () -> Void
  ) {
    locked = initiallyLocked
    self.eligible = eligible
    self.prepare = prepare
    self.discard = discard
  }

  func request() {
    guard isEligible else { invalidate(); return }
    guard task == nil else { return }
    let id = generation
    task = Task { [weak self] in
      guard let self, !Task.isCancelled else { return }
      _ = await self.prepare()
      if self.generation == id { self.task = nil }
    }
  }

  func invalidate() {
    generation = UUID()
    task?.cancel()
    task = nil
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

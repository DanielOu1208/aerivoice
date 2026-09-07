import ApplicationServices
import Foundation

/// A cooperative end-to-end budget. Every synchronous AX request receives at most
/// the remaining budget; no detached timeout task can outlive it and paste later.
struct InsertionDeadline {
  private let expiresAt: TimeInterval
  private let now: () -> TimeInterval

  init(
    seconds: TimeInterval = 0.75,
    now: @escaping () -> TimeInterval = {
      ProcessInfo.processInfo.systemUptime
    }
  ) {
    self.now = now
    expiresAt = now() + seconds
  }

  var isExpired: Bool { now() >= expiresAt }

  func remainingDelay(maximum: TimeInterval) -> TimeInterval? {
    let remaining = expiresAt - now()
    guard remaining > 0, !Task.isCancelled else { return nil }
    return min(maximum, remaining)
  }

  func timeout(maximum: Float = 0.1) -> Float? {
    let remaining = expiresAt - now()
    guard remaining > 0, !Task.isCancelled else { return nil }
    return min(maximum, Float(remaining))
  }
}

enum AXQuery {
  /// Retry reads only, with a refreshed timeout before each attempt. Mutations
  /// deliberately do not use this helper because a timeout is not non-delivery.
  static func read<Value>(
    prepare: () -> Bool, perform: () -> (AXError, Value?)
  ) -> (AXError, Value?) {
    for attempt in 0..<2 {
      guard prepare() else { return (.cannotComplete, nil) }
      let response = perform()
      if response.0 == .cannotComplete, attempt == 0 { continue }
      return response
    }
    return (.cannotComplete, nil)
  }
}

enum ParentLookup<Element> {
  case parent(Element)
  case root
  case unavailable
}

enum EditorAncestry {
  /// Only an explicitly verified application root completes the security walk.
  /// nil means unavailable metadata; a failure is a definite rejection and is
  /// never retried as if accessibility were still loading.
  static func resolve<Element>(
    startingAt focus: Element, maximumDepth: Int = 32,
    traits: (Element) -> TextTargetTraits,
    parent: (Element) -> ParentLookup<Element>,
    same: (Element, Element) -> Bool,
    shouldStop: () -> Bool
  ) -> Result<Element, PasteBlockReason>? {
    var current = focus
    var visited: [Element] = []
    var editor: Element?
    for _ in 0..<maximumDepth {
      guard !shouldStop() else { return nil }
      guard !visited.contains(where: { same($0, current) }) else {
        return .failure(.targetUnavailable)
      }
      visited.append(current)
      let evidence = traits(current)
      guard !shouldStop(), evidence.secureTextStatus != .unknown else { return nil }
      if evidence.secureTextStatus == .secure { return .failure(.secureField) }
      if evidence.enabled == false || (editor == nil && evidence.editable == false) {
        return .failure(.readOnlyTarget)
      }
      if editor == nil, TextTargetPolicy.isTextTarget(evidence) { editor = current }
      let result = parent(current)
      guard !shouldStop() else { return nil }
      switch result {
      case .root:
        return editor.map { .success($0) } ?? .failure(.unsupportedField)
      case .parent(let next): current = next
      case .unavailable: return nil
      }
    }
    return .failure(.targetUnavailable)
  }
}

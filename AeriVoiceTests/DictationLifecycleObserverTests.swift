import Foundation
import XCTest

@testable import AeriVoice

@MainActor
final class DictationLifecycleObserverTests: XCTestCase {
  func testCancelledStartRemainsActiveUntilSuspendedReadinessReturns() async throws {
    let observer = LifecycleSpy()
    let readiness = LifecycleReadiness()
    let coordinator = makeCoordinator(observer: observer, readiness: readiness)
    coordinator.toggle()
    let startID = try XCTUnwrap(observer.active.first { $0.value == "start" }?.key)
    try await waitUntil { readiness.pending != nil }

    coordinator.cancel()
    XCTAssertEqual(observer.active[startID], "start")
    XCTAssertFalse(observer.finished.contains(startID))
    readiness.pending?.resume(returning: true)
    readiness.pending = nil
    try await waitUntil { observer.finished.contains(startID) }
    XCTAssertNil(observer.active[startID])
    try await waitUntil { observer.active.isEmpty }
    XCTAssertEqual(coordinator.phase, .idle)
    XCTAssertEqual(observer.finished.count, observer.started.count)
  }

  func testReadinessErrorUsesInjectedNotificationSinkAndTracksIdleDelay() async throws {
    let observer = LifecycleSpy()
    let notifications = LifecycleNotifications()
    let coordinator = makeCoordinator(
      observer: observer, readiness: LifecycleReadiness(),
      credentials: LifecycleCredentials(value: nil), notifications: notifications)
    coordinator.toggle()
    try await waitUntil { notifications.errors.count == 1 }
    XCTAssertEqual(notifications.errors.first, AppError.missingSonioxKey.localizedDescription)
    XCTAssertEqual(Set(observer.active.values), ["readinessIdleDelay"])
    guard case .error = coordinator.phase else { return XCTFail("Expected readiness error") }
    try await waitUntil { observer.active.isEmpty }
    XCTAssertEqual(coordinator.phase, .idle)
    XCTAssertEqual(observer.finished.count, observer.started.count)
  }

  private func makeCoordinator(
    observer: LifecycleSpy, readiness: LifecycleReadiness,
    credentials: LifecycleCredentials = LifecycleCredentials(value: "test-key"),
    notifications: LifecycleNotifications = LifecycleNotifications()
  ) -> DictationCoordinator {
    let defaults = UserDefaults(suiteName: "DictationLifecycleObserverTests.\(UUID())")!
    let preferences = AppPreferences(defaults: defaults)
    preferences.soundCues = false
    preferences.latencyLogging = false
    return DictationCoordinator(
      preferences: preferences, credentials: credentials,
      muter: LifecycleMuter(), notch: LifecycleNotch(), readiness: readiness,
      lifecycleObserver: observer, notifications: notifications)
  }

  private func waitUntil(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(4))
    while !condition(), ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(5))
    }
    XCTAssertTrue(condition(), "Lifecycle condition did not settle")
  }
}

@MainActor
private final class LifecycleSpy: DictationLifecycleObserving {
  var active: [UUID: String] = [:]
  var started: Set<UUID> = []
  var finished: Set<UUID> = []

  func workStarted(id: UUID, kind: String) {
    XCTAssertTrue(started.insert(id).inserted)
    active[id] = kind
  }

  func workFinished(id: UUID) {
    XCTAssertNotNil(active.removeValue(forKey: id))
    XCTAssertTrue(finished.insert(id).inserted)
  }
}

@MainActor
private final class LifecycleReadiness: DictationReadinessChecking {
  var pending: CheckedContinuation<Bool, Never>?
  func requestMicrophone() async -> Bool {
    await withCheckedContinuation { pending = $0 }
  }
  func accessibilityReady(prompt: Bool) -> Bool { true }
}

private struct LifecycleCredentials: CredentialReading {
  let value: String?
  func value(for kind: CredentialKind) -> String? { value }
}

@MainActor
private final class LifecycleNotifications: DictationNotificationPosting {
  var errors: [String] = []
  func postReadinessError(_ error: Error) { errors.append(error.localizedDescription) }
}

private final class LifecycleMuter: OutputMuting {
  func mute() -> Bool { true }
  func restore() {}
}

@MainActor
private final class LifecycleNotch: NotchPresenting {
  func present(state: NotchState) {}
  func hide(after delay: Duration) {}
}

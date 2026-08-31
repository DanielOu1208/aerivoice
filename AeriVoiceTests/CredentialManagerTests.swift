import XCTest
@testable import AeriVoice

@MainActor
final class CredentialManagerTests: XCTestCase {
  func testCancelPreventsLateSaveWhenValidatorIgnoresCancellation() async throws {
    let store = FakeCredentialStore(values: [.openRouter: "existing"])
    let validator = SuspendedCredentialValidator()
    let manager = CredentialManager(store: store, validator: validator)

    manager.beginValidation(
      "replacement", kind: .openRouter, configuration: .openRouterTestConfiguration)
    try await validator.waitUntilCalled()
    manager.cancelValidation(.openRouter)
    validator.finish()
    try await validator.waitUntilReturned()
    await Task.yield()

    XCTAssertEqual(store.value(for: .openRouter), "existing")
    XCTAssertEqual(manager.status(for: .openRouter), .saved)
  }

  func testInitialValidationCanBeCancelledWithoutSaving() async throws {
    let store = FakeCredentialStore()
    let validator = SuspendedCredentialValidator()
    let manager = CredentialManager(store: store, validator: validator)

    manager.beginValidation(
      "new-key", kind: .openRouter, configuration: .openRouterTestConfiguration)
    try await validator.waitUntilCalled()
    manager.cancelValidation(.openRouter)
    validator.finish()
    try await validator.waitUntilReturned()
    await Task.yield()

    XCTAssertNil(store.value(for: .openRouter))
    XCTAssertEqual(manager.status(for: .openRouter), .missing)
  }

  func testRemovePreventsValidationFromRecreatingCredential() async throws {
    let store = FakeCredentialStore(values: [.openRouter: "existing"])
    let validator = SuspendedCredentialValidator()
    let manager = CredentialManager(store: store, validator: validator)

    manager.beginValidation(
      "replacement", kind: .openRouter, configuration: .openRouterTestConfiguration)
    try await validator.waitUntilCalled()
    manager.remove(.openRouter)
    validator.finish()
    try await validator.waitUntilReturned()
    await Task.yield()

    XCTAssertNil(store.value(for: .openRouter))
    XCTAssertEqual(manager.status(for: .openRouter), .missing)
  }

  func testFailedReplacementPreservesExistingCredential() async throws {
    let store = FakeCredentialStore(values: [.groq: "existing"])
    let validator = FailingCredentialValidator()
    let manager = CredentialManager(store: store, validator: validator)

    manager.beginValidation("replacement", kind: .groq, configuration: .groqTestConfiguration)
    try await validator.waitUntilCalled()

    XCTAssertEqual(store.value(for: .groq), "existing")
    guard case .error(let message) = manager.status(for: .groq) else {
      return XCTFail("Expected failed validation status")
    }
    XCTAssertEqual(message, FailingCredentialValidator.failure.localizedDescription)
  }

  func testSuccessfulReplacementSavesNewCredential() async throws {
    let store = FakeCredentialStore(values: [.soniox: "existing"])
    let validator = SuccessfulCredentialValidator()
    let manager = CredentialManager(store: store, validator: validator)

    manager.beginValidation(" replacement ", kind: .soniox, configuration: nil)
    try await validator.waitUntilCalled()

    XCTAssertEqual(store.value(for: .soniox), "replacement")
    XCTAssertEqual(manager.status(for: .soniox), .saved)
  }
}

private extension CleanupConfiguration {
  static let openRouterTestConfiguration = CleanupConfiguration(
    model: .gemini37Flash, reasoningEffort: .low)
  static let groqTestConfiguration = CleanupConfiguration(
    model: .qwen38_27BGroq, reasoningEffort: .none)
}

private final class FakeCredentialStore: CredentialStoring, @unchecked Sendable {
  private var values: [CredentialKind: String]

  init(values: [CredentialKind: String] = [:]) {
    self.values = values
  }

  func value(for kind: CredentialKind) -> String? { values[kind] }
  func save(_ value: String, for kind: CredentialKind) throws { values[kind] = value }
  func remove(_ kind: CredentialKind) throws { values[kind] = nil }
}

private final class SuspendedCredentialValidator: CredentialValidating, @unchecked Sendable {
  private var continuation: CheckedContinuation<Void, Never>?
  private var wasCalled = false
  private var hasReturned = false

  func validate(
    _ value: String, kind: CredentialKind, configuration: CleanupConfiguration?
  ) async throws {
    wasCalled = true
    await withCheckedContinuation { continuation = $0 }
    hasReturned = true
  }

  func waitUntilCalled() async throws {
    try await waitUntil { wasCalled }
  }

  func finish() {
    continuation?.resume()
    continuation = nil
  }

  func waitUntilReturned() async throws {
    try await waitUntil { hasReturned }
  }
}

private final class FailingCredentialValidator: CredentialValidating, @unchecked Sendable {
  static let failure = NSError(
    domain: "CredentialManagerTests", code: 1,
    userInfo: [NSLocalizedDescriptionKey: "Rejected credential"])
  private var wasCalled = false

  func validate(
    _ value: String, kind: CredentialKind, configuration: CleanupConfiguration?
  ) async throws {
    wasCalled = true
    throw Self.failure
  }

  func waitUntilCalled() async throws {
    try await waitUntil { wasCalled }
  }
}

private final class SuccessfulCredentialValidator: CredentialValidating, @unchecked Sendable {
  private var wasCalled = false

  func validate(
    _ value: String, kind: CredentialKind, configuration: CleanupConfiguration?
  ) async throws {
    wasCalled = true
  }

  func waitUntilCalled() async throws {
    try await waitUntil { wasCalled }
  }
}

private enum TestWaitError: Error {
  case timedOut
}

@MainActor
private func waitUntil(_ condition: () -> Bool) async throws {
  let deadline = ContinuousClock.now.advanced(by: .seconds(1))
  while !condition() {
    guard ContinuousClock.now < deadline else { throw TestWaitError.timedOut }
    await Task.yield()
  }
  await Task.yield()
}

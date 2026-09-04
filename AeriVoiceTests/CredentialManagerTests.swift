import XCTest
@testable import AeriVoice

@MainActor
final class CredentialManagerTests: XCTestCase {
  func testCredentialPresenceUsesInitialSnapshotWithoutRepeatedStoreReads() {
    let store = FakeCredentialStore(values: [.soniox: "existing"])
    let manager = CredentialManager(store: store)

    XCTAssertEqual(store.presenceReadCount(for: .soniox), 1)
    for _ in 0..<50 {
      XCTAssertTrue(manager.hasCredential(.soniox))
      XCTAssertFalse(manager.hasCredential(.openRouter))
    }
    XCTAssertEqual(store.presenceReadCount(for: .soniox), 1)
    XCTAssertEqual(store.presenceReadCount(for: .openRouter), 1)
  }

  func testCredentialRefreshUpdatesSnapshotWithOneReadPerKind() throws {
    let store = FakeCredentialStore()
    let manager = CredentialManager(store: store)
    try store.save("new-key", for: .openRouter)

    manager.refreshStoredCredentials()

    XCTAssertTrue(manager.hasCredential(.openRouter))
    XCTAssertEqual(manager.status(for: .openRouter), .saved)
    XCTAssertEqual(store.presenceReadCount(for: .soniox), 2)
    XCTAssertEqual(store.presenceReadCount(for: .openRouter), 2)
    XCTAssertEqual(store.presenceReadCount(for: .groq), 2)
    XCTAssertEqual(store.presenceReadCount(for: .cerebras), 2)
  }

  func testLegacyCredentialDetectionDoesNotReadSecret() {
    let store = FakeCredentialStore()
    let legacyStore = FakeCredentialStore(values: [.soniox: "legacy-key"])
    let manager = CredentialManager(store: store, legacyStore: legacyStore)

    XCTAssertTrue(manager.canImportLegacyCredential(.soniox))
    XCTAssertFalse(manager.canImportLegacyCredential(.openRouter))
    XCTAssertEqual(legacyStore.presenceReadCount(for: .soniox), 1)
    XCTAssertEqual(legacyStore.valueReadCount(for: .soniox), 0)
  }

  func testLegacyImportValidatesAndCopiesWithoutDeletingLegacyCredential() async throws {
    let store = FakeCredentialStore()
    let legacyStore = FakeCredentialStore(values: [.openRouter: " legacy-key "])
    let validator = SuccessfulCredentialValidator()
    let manager = CredentialManager(
      store: store, legacyStore: legacyStore, validator: validator)

    manager.beginLegacyImport(
      kind: .openRouter, configuration: .openRouterTestConfiguration)
    try await validator.waitUntilCalled()
    try await waitUntil { manager.status(for: .openRouter) == .saved }

    XCTAssertEqual(store.value(for: .openRouter), "legacy-key")
    XCTAssertEqual(store.addIfMissingCount(for: .openRouter), 1)
    XCTAssertEqual(legacyStore.value(for: .openRouter), " legacy-key ")
    XCTAssertEqual(legacyStore.removeCount(for: .openRouter), 0)
    XCTAssertTrue(manager.hasCredential(.openRouter))
    XCTAssertFalse(manager.canImportLegacyCredential(.openRouter))
  }

  func testLegacyImportNeverOverwritesCurrentCredential() {
    let store = FakeCredentialStore(values: [.groq: "current-key"])
    let legacyStore = FakeCredentialStore(values: [.groq: "legacy-key"])
    let manager = CredentialManager(store: store, legacyStore: legacyStore)

    manager.beginLegacyImport(kind: .groq, configuration: .groqTestConfiguration)

    XCTAssertEqual(store.value(for: .groq), "current-key")
    XCTAssertEqual(manager.status(for: .groq), .saved)
    XCTAssertFalse(manager.canImportLegacyCredential(.groq))
    XCTAssertEqual(legacyStore.valueReadCount(for: .groq), 0)
    XCTAssertEqual(store.addIfMissingCount(for: .groq), 0)
  }

  func testLegacyImportDoesNotOverwriteCredentialAddedDuringValidation() async throws {
    let store = FakeCredentialStore()
    let legacyStore = FakeCredentialStore(values: [.openRouter: "legacy-key"])
    let validator = SuspendedCredentialValidator()
    let manager = CredentialManager(
      store: store, legacyStore: legacyStore, validator: validator)

    manager.beginLegacyImport(
      kind: .openRouter, configuration: .openRouterTestConfiguration)
    try await validator.waitUntilCalled()
    try store.save("new-current-key", for: .openRouter)
    validator.finish()
    try await validator.waitUntilReturned()
    try await waitUntil { manager.status(for: .openRouter) == .saved }

    XCTAssertEqual(store.value(for: .openRouter), "new-current-key")
    XCTAssertEqual(store.addIfMissingCount(for: .openRouter), 1)
    XCTAssertEqual(legacyStore.value(for: .openRouter), "legacy-key")
  }

  func testCancellingLegacyImportPreventsLateSave() async throws {
    let store = FakeCredentialStore()
    let legacyStore = FakeCredentialStore(values: [.openRouter: "legacy-key"])
    let validator = SuspendedCredentialValidator()
    let manager = CredentialManager(
      store: store, legacyStore: legacyStore, validator: validator)

    manager.beginLegacyImport(
      kind: .openRouter, configuration: .openRouterTestConfiguration)
    try await validator.waitUntilCalled()
    manager.cancelValidation(.openRouter)
    validator.finish()
    try await validator.waitUntilReturned()
    await Task.yield()

    XCTAssertNil(store.value(for: .openRouter))
    XCTAssertEqual(manager.status(for: .openRouter), .missing)
    XCTAssertTrue(manager.canImportLegacyCredential(.openRouter))
  }

  func testUnreadableLegacyCredentialFallsBackToManualEntry() async throws {
    let store = FakeCredentialStore()
    let legacyStore = FakeCredentialStore(
      values: [.soniox: "legacy-key"], unreadableKinds: [.soniox])
    let manager = CredentialManager(store: store, legacyStore: legacyStore)

    manager.beginLegacyImport(kind: .soniox, configuration: nil)
    try await waitUntil {
      if case .error = manager.status(for: .soniox) { return true }
      return false
    }

    XCTAssertFalse(manager.hasCredential(.soniox))
    XCTAssertNil(store.value(for: .soniox))
    XCTAssertEqual(legacyStore.valueReadCount(for: .soniox), 1)
    XCTAssertEqual(
      manager.status(for: .soniox),
      .error("macOS couldn’t read this beta.1 key. Paste it again below to reconnect."))
  }

  func testFailedLegacyValidationDoesNotSaveCredential() async throws {
    let store = FakeCredentialStore()
    let legacyStore = FakeCredentialStore(values: [.groq: "legacy-key"])
    let validator = FailingCredentialValidator()
    let manager = CredentialManager(
      store: store, legacyStore: legacyStore, validator: validator)

    manager.beginLegacyImport(kind: .groq, configuration: .groqTestConfiguration)
    try await validator.waitUntilCalled()
    try await waitUntil {
      if case .error = manager.status(for: .groq) { return true }
      return false
    }

    XCTAssertNil(store.value(for: .groq))
    XCTAssertEqual(store.addIfMissingCount(for: .groq), 0)
    XCTAssertEqual(legacyStore.value(for: .groq), "legacy-key")
  }

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
    XCTAssertFalse(manager.hasCredential(.openRouter))
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
    XCTAssertFalse(manager.hasCredential(.openRouter))
  }

  func testFailedReplacementPreservesExistingCredential() async throws {
    let store = FakeCredentialStore(values: [.groq: "existing"])
    let validator = FailingCredentialValidator()
    let manager = CredentialManager(store: store, validator: validator)

    manager.beginValidation("replacement", kind: .groq, configuration: .groqTestConfiguration)
    try await validator.waitUntilCalled()

    XCTAssertEqual(store.value(for: .groq), "existing")
    XCTAssertTrue(manager.hasCredential(.groq))
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
    XCTAssertTrue(manager.hasCredential(.soniox))
  }

  func testSuccessfulCerebrasValidationSavesCredential() async throws {
    let store = FakeCredentialStore()
    let validator = SuccessfulCredentialValidator()
    let manager = CredentialManager(store: store, validator: validator)

    manager.beginValidation(
      " cerebras-key ", kind: .cerebras, configuration: .cerebrasTestConfiguration)
    try await validator.waitUntilCalled()
    try await waitUntil { manager.status(for: .cerebras) == .saved }

    XCTAssertEqual(store.value(for: .cerebras), "cerebras-key")
    XCTAssertTrue(manager.hasCredential(.cerebras))
  }
}

private extension CleanupConfiguration {
  static let openRouterTestConfiguration = CleanupConfiguration(
    model: .gemini37Flash, reasoningEffort: .low)
  static let groqTestConfiguration = CleanupConfiguration(
    model: .qwen38_27BGroq, reasoningEffort: .none)
  static let cerebrasTestConfiguration = CleanupConfiguration(
    model: .qwen38_27BCerebras, reasoningEffort: .none)
}

private final class FakeCredentialStore: CredentialStoring, @unchecked Sendable {
  private var values: [CredentialKind: String]
  private let unreadableKinds: Set<CredentialKind>
  private var presenceReadCounts: [CredentialKind: Int] = [:]
  private var valueReadCounts: [CredentialKind: Int] = [:]
  private var addIfMissingCounts: [CredentialKind: Int] = [:]
  private var removeCounts: [CredentialKind: Int] = [:]

  init(
    values: [CredentialKind: String] = [:], unreadableKinds: Set<CredentialKind> = []
  ) {
    self.values = values
    self.unreadableKinds = unreadableKinds
  }

  func value(for kind: CredentialKind) -> String? {
    valueReadCounts[kind, default: 0] += 1
    return unreadableKinds.contains(kind) ? nil : values[kind]
  }
  func containsCredential(_ kind: CredentialKind) -> Bool {
    presenceReadCounts[kind, default: 0] += 1
    return values[kind].map { !$0.isEmpty } == true
  }
  func addIfMissing(_ value: String, for kind: CredentialKind) throws -> Bool {
    addIfMissingCounts[kind, default: 0] += 1
    guard values[kind] == nil else { return false }
    values[kind] = value
    return true
  }
  func save(_ value: String, for kind: CredentialKind) throws { values[kind] = value }
  func remove(_ kind: CredentialKind) throws {
    removeCounts[kind, default: 0] += 1
    values[kind] = nil
  }

  func presenceReadCount(for kind: CredentialKind) -> Int {
    presenceReadCounts[kind, default: 0]
  }

  func valueReadCount(for kind: CredentialKind) -> Int {
    valueReadCounts[kind, default: 0]
  }

  func addIfMissingCount(for kind: CredentialKind) -> Int {
    addIfMissingCounts[kind, default: 0]
  }

  func removeCount(for kind: CredentialKind) -> Int {
    removeCounts[kind, default: 0]
  }
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

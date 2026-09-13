import XCTest

@testable import AeriVoice

@MainActor
final class OpenRouterCatalogStoreTests: XCTestCase {
  func testCacheSurvivesRelaunchAndRefreshesOnlyWhenStaleOrForced() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let cache = folder.appending(path: "catalog.json")
    let clock = CatalogTestClock()
    let fixture = try entries()
    let source = CatalogTestSource(entries: fixture)
    let first = OpenRouterCatalogStore(
      cacheURL: cache, now: { clock.date }, fetch: { try await source.fetch() })
    await first.refresh()
    let countAfterFirst = await source.calls
    XCTAssertEqual(countAfterFirst, 1)
    XCTAssertEqual(first.entries, fixture)
    let restored = OpenRouterCatalogStore(
      cacheURL: cache, now: { clock.date }, fetch: { try await source.fetch() })
    XCTAssertEqual(restored.entries, fixture)
    XCTAssertEqual(restored.fetchedAt, clock.date)
    XCTAssertFalse(restored.needsRefresh)
    await restored.refresh()
    let countAfterCached = await source.calls
    XCTAssertEqual(countAfterCached, 1)
    await restored.refresh(force: true)
    let countAfterForced = await source.calls
    XCTAssertEqual(countAfterForced, 2)
    clock.date += OpenRouterCatalogStore.refreshInterval
    XCTAssertTrue(restored.needsRefresh)
    await restored.refresh()
    let countAfterStale = await source.calls
    XCTAssertEqual(countAfterStale, 3)
  }

  func testOfflineRefreshPreservesCacheAndLastSuccessfulTime() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let cache = folder.appending(path: "catalog.json")
    let source = CatalogTestSource(entries: try entries())
    let store = OpenRouterCatalogStore(cacheURL: cache, fetch: { try await source.fetch() })
    await store.refresh()
    let before = try Data(contentsOf: cache)
    let fetchedAt = store.fetchedAt
    await source.setOffline()
    await store.refresh(force: true)
    XCTAssertEqual(store.fetchedAt, fetchedAt)
    XCTAssertFalse(store.entries.isEmpty)
    XCTAssertNotNil(store.errorMessage)
    XCTAssertEqual(try Data(contentsOf: cache), before)
    XCTAssertFalse(store.isRefreshing)
    let restored = OpenRouterCatalogStore(cacheURL: cache)
    XCTAssertEqual(restored.entries, store.entries)
  }

  func testCorruptCacheRecoversAndEmptyRefreshCannotReplaceGoodData() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let cache = folder.appending(path: "catalog.json")
    try Data("broken".utf8).write(to: cache)
    let source = CatalogTestSource(entries: try entries())
    let store = OpenRouterCatalogStore(cacheURL: cache, fetch: { try await source.fetch() })
    XCTAssertTrue(store.needsRefresh)
    await store.refresh()
    XCTAssertNil(store.errorMessage)
    let good = store.entries
    let before = try Data(contentsOf: cache)
    await source.replace(with: [])
    await store.refresh(force: true)
    XCTAssertEqual(store.entries, good)
    XCTAssertEqual(try Data(contentsOf: cache), before)
    XCTAssertNotNil(store.errorMessage)
  }

  func testConcurrentRefreshesShareOneRequest() async throws {
    let source = CatalogTestSource(entries: try entries(), suspended: true)
    let store = OpenRouterCatalogStore(cacheURL: nil, fetch: { try await source.fetch() })
    let first = Task { await store.refresh() }
    await source.waitUntilStarted()
    let second = Task { await store.refresh(force: true) }
    // The second MainActor task reaches its first suspension before this task resumes.
    await Task.yield()
    await source.release()
    await first.value
    await second.value
    let count = await source.calls
    XCTAssertEqual(count, 1)
    XCTAssertFalse(store.isRefreshing)
    XCTAssertFalse(store.entries.isEmpty)
  }

  func testChoicesPersistPerProviderAndRefreshDoesNotRewriteSavedEffort() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let suite = "AeriVoiceTests.CachedReasoning.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer {
      try? FileManager.default.removeItem(at: folder)
      defaults.removePersistentDomain(forName: suite)
    }
    // Legacy direct Groq choice must not bleed into OpenRouter for the same ID.
    defaults.set(
      try JSONEncoder().encode(["qwen/qwen3.8-27b": "low"]), forKey: "cleanupReasoningEfforts")
    let original = try entries(id: "qwen/qwen3.8-27b", efforts: ["future_level", "high", "low"])
    let source = CatalogTestSource(entries: original)
    let cache = folder.appending(path: "catalog.json")
    let store = OpenRouterCatalogStore(cacheURL: cache, fetch: { try await source.fetch() })
    let preferences = AppPreferences(defaults: defaults, openRouterCatalog: store)
    preferences.cleanupModel = try XCTUnwrap(CleanupModel(openRouterID: "qwen/qwen3.8-27b"))
    await store.refresh()
    XCTAssertEqual(preferences.cleanupReasoningEffort, .automatic)
    let future = try XCTUnwrap(CleanupReasoningEffort(rawValue: "future_level"))
    preferences.cleanupReasoningEffort = future
    let snapshot = preferences.cleanupConfiguration
    XCTAssertEqual(snapshot.reasoningEffort, future)
    await source.replace(with: try entries(id: "qwen/qwen3.8-27b", efforts: ["high", "low"]))
    await store.refresh(force: true)
    XCTAssertTrue(preferences.savedCleanupReasoningIsUnavailable)
    XCTAssertEqual(preferences.cleanupReasoningEffort, .automatic)
    XCTAssertEqual(snapshot.reasoningEffort, future)
    await source.replace(with: original)
    await store.refresh(force: true)
    XCTAssertEqual(preferences.cleanupReasoningEffort, future)
    let restored = AppPreferences(
      defaults: defaults, openRouterCatalog: OpenRouterCatalogStore(cacheURL: cache))
    XCTAssertEqual(restored.cleanupReasoningEffort, future)
    restored.cleanupProvider = .groq
    XCTAssertEqual(restored.cleanupReasoningEffort, .low)
    restored.cleanupReasoningEffort = .none
    restored.cleanupProvider = .openRouter
    XCTAssertEqual(restored.cleanupReasoningEffort, future)
  }

  func testExplicitModelDefaultSurvivesMissingPresetMetadataAndCache() async throws {
    let suite = "AeriVoiceTests.ReasoningDefault.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let source = CatalogTestSource(entries: try entries(id: CleanupModel.gemini37Flash.rawValue))
    let store = OpenRouterCatalogStore(cacheURL: nil, fetch: { try await source.fetch() })
    let preferences = AppPreferences(defaults: defaults, openRouterCatalog: store)
    preferences.cleanupModel = .gemini37Flash
    await store.refresh()
    preferences.cleanupReasoningEffort = .automatic
    await source.replace(with: try entries(id: "vendor/other-model"))
    await store.refresh(force: true)
    XCTAssertEqual(preferences.cleanupReasoningEffort, .automatic)
    XCTAssertEqual(preferences.cleanupConfiguration.reasoningEffort, .automatic)
    let restored = AppPreferences(
      defaults: defaults, openRouterCatalog: OpenRouterCatalogStore(cacheURL: nil))
    XCTAssertEqual(restored.cleanupReasoningEffort, .automatic)
    XCTAssertTrue(restored.supportedCleanupReasoningEfforts.contains(.automatic))
    XCTAssertEqual(
      CleanupConfiguration(model: .gemini37Flash, reasoningEffort: .automatic).reasoningEffort,
      .automatic)
  }

  func testExplicitResetDiscardsUnavailableChoice() async throws {
    let suite = "AeriVoiceTests.ReasoningReset.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let original = try entries()
    let source = CatalogTestSource(entries: original)
    let store = OpenRouterCatalogStore(cacheURL: nil, fetch: { try await source.fetch() })
    let preferences = AppPreferences(defaults: defaults, openRouterCatalog: store)
    preferences.cleanupModel = try XCTUnwrap(CleanupModel(openRouterID: "vendor/chat"))
    await store.refresh()
    preferences.cleanupReasoningEffort = .high
    await source.replace(with: try entries(efforts: []))
    await store.refresh(force: true)
    XCTAssertTrue(preferences.savedCleanupReasoningIsUnavailable)
    preferences.cleanupReasoningEffort = .automatic
    XCTAssertFalse(preferences.savedCleanupReasoningIsUnavailable)
    await source.replace(with: original)
    await store.refresh(force: true)
    XCTAssertEqual(preferences.cleanupReasoningEffort, .automatic)
  }

  private func entries(id: String = "vendor/chat", efforts: [String] = ["high", "low"]) throws
    -> [OpenRouterCatalogEntry]
  {
    let data = try JSONSerialization.data(withJSONObject: [
      "data": [
        [
          "id": id, "name": "Test Model",
          "architecture": ["input_modalities": ["text"], "output_modalities": ["text"]],
          "reasoning": ["supported_efforts": efforts, "mandatory": true, "default_effort": "low"],
        ]
      ]
    ])
    return try OpenRouterModelCatalog.decode(data)
  }
}

@MainActor
private final class CatalogTestClock {
  var date = Date(timeIntervalSince1970: 2_000_000_000)
}

private actor CatalogTestSource {
  var calls = 0
  private var entries: [OpenRouterCatalogEntry]
  private var offline = false
  private let suspended: Bool
  private var gate: CheckedContinuation<Void, Never>?
  private var startWaiters: [CheckedContinuation<Void, Never>] = []

  init(entries: [OpenRouterCatalogEntry], suspended: Bool = false) {
    self.entries = entries
    self.suspended = suspended
  }

  func fetch() async throws -> [OpenRouterCatalogEntry] {
    calls += 1
    for waiter in startWaiters { waiter.resume() }
    startWaiters = []
    if suspended { await withCheckedContinuation { gate = $0 } }
    if offline { throw URLError(.notConnectedToInternet) }
    return entries
  }

  func waitUntilStarted() async {
    if calls > 0 { return }
    await withCheckedContinuation { startWaiters.append($0) }
  }

  func release() {
    gate?.resume()
    gate = nil
  }
  func setOffline() { offline = true }
  func replace(with entries: [OpenRouterCatalogEntry]) { self.entries = entries }
}

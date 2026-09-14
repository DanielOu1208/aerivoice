import Combine
import Foundation

@MainActor
final class OpenRouterCatalogStore: ObservableObject {
  @Published private(set) var entries: [OpenRouterCatalogEntry] = []
  @Published private(set) var fetchedAt: Date?
  @Published private(set) var isRefreshing = false
  @Published private(set) var errorMessage: String?

  static let refreshInterval: TimeInterval = 24 * 60 * 60
  static var defaultCacheURL: URL {
    FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      .appending(path: "com.danielou.AeriVoice/openrouter-catalog-v1.json")
  }

  private let cacheURL: URL?
  private let fetch: @Sendable () async throws -> [OpenRouterCatalogEntry]
  private let now: () -> Date
  private var refreshTask: Task<Void, Never>?

  init(
    cacheURL: URL? = OpenRouterCatalogStore.defaultCacheURL,
    now: @escaping () -> Date = Date.init,
    fetch: @escaping @Sendable () async throws -> [OpenRouterCatalogEntry] = {
      try await OpenRouterModelCatalog().fetch()
    }
  ) {
    self.cacheURL = cacheURL
    self.now = now
    self.fetch = fetch
    if let cacheURL, let data = try? Data(contentsOf: cacheURL),
      let cached = try? JSONDecoder().decode(CachedCatalog.self, from: data),
      cached.schemaVersion == 1, !cached.entries.isEmpty
    {
      entries = cached.entries.filter(\.isCleanupCompatible)
      fetchedAt = cached.fetchedAt
    }
  }

  func entry(for model: CleanupModel) -> OpenRouterCatalogEntry? {
    guard model.provider == .openRouter else { return nil }
    return entries.first { $0.id == model.rawValue }
  }

  var needsRefresh: Bool {
    guard let fetchedAt, !entries.isEmpty else { return true }
    let age = now().timeIntervalSince(fetchedAt)
    return age < 0 || age >= Self.refreshInterval
  }

  // One request serves both the settings page and model picker. Closing a view
  // does not cancel a refresh that is still useful to the other view or next launch.
  func cancelRefresh() { refreshTask?.cancel() }

  func refresh(force: Bool = false) async {
    guard !AppNetworkPolicy.shared.isOffline else { return }
    if let refreshTask {
      await refreshTask.value
      return
    }
    guard force || needsRefresh else { return }
    isRefreshing = true
    errorMessage = nil
    let task = Task { @MainActor in
      defer {
        self.isRefreshing = false
        self.refreshTask = nil
      }
      do {
        let loaded = try await self.fetch()
        try Task.checkCancellation()
        try AppNetworkPolicy.shared.checkAllowed()
        guard !loaded.isEmpty else {
          throw AppError.provider("OpenRouter returned an empty model catalog.")
        }
        self.entries = loaded
        self.fetchedAt = self.now()
        do {
          try self.saveCache()
        } catch {
          self.errorMessage =
            "Models refreshed, but the cache couldn’t be saved for the next launch."
        }
      } catch {
        guard !Task.isCancelled, !AppNetworkPolicy.shared.isOffline else { return }
        self.errorMessage =
          self.entries.isEmpty
          ? "Couldn’t load OpenRouter’s catalog. Presets and custom model IDs are still available."
          : "Couldn’t refresh OpenRouter’s catalog. Using the saved models and reasoning options."
      }
    }
    refreshTask = task
    await task.value
  }

  private func saveCache() throws {
    guard let cacheURL, let fetchedAt else { return }
    let cached = CachedCatalog(schemaVersion: 1, fetchedAt: fetchedAt, entries: entries)
    let data = try JSONEncoder().encode(cached)
    try FileManager.default.createDirectory(
      at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: cacheURL, options: .atomic)
  }

  private struct CachedCatalog: Codable {
    let schemaVersion: Int
    let fetchedAt: Date
    let entries: [OpenRouterCatalogEntry]
  }
}

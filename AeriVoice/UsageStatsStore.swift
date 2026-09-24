import Foundation

actor UsageStatsStore {
  static var defaultURL: URL {
    #if DEBUG
      if let directory = ProcessInfo.processInfo.environment["AERIVOICE_USAGE_STATS_TEST_DIRECTORY"],
        directory.hasPrefix("/") {
        return URL(fileURLWithPath: directory).appending(path: "totals-v1.json")
      }
    #endif
    return AppStoragePaths.applicationSupport.appending(path: "UsageStats/totals-v1.json")
  }

  enum StoreError: Error { case unsupportedOrInvalidData }
  private let url: URL

  init(url: URL) { self.url = url }

  func load() throws -> UsageStatsData {
    guard FileManager.default.fileExists(atPath: url.path) else { return UsageStatsData() }
    let data = try JSONDecoder().decode(UsageStatsData.self, from: Data(contentsOf: url))
    guard data.isValid else { throw StoreError.unsupportedOrInvalidData }
    return data
  }

  func save(_ data: UsageStatsData) throws {
    guard data.isValid else { throw StoreError.unsupportedOrInvalidData }
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                           withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    try encoder.encode(data).write(to: url, options: .atomic)
  }

  func clear() throws {
    if FileManager.default.fileExists(atPath: url.path) {
      try FileManager.default.removeItem(at: url)
    }
  }
}

@MainActor
final class UsageStatsModel: ObservableObject, UsageStatsRecording {
  @Published private(set) var data = UsageStatsData()
  @Published private(set) var enabled: Bool
  @Published private(set) var isLoaded = false
  @Published private(set) var storageError: String?

  private let defaults: UserDefaults
  private let store: UsageStatsStore
  private var generation = UUID()
  private var active: Set<UsageSession> = []
  private var pending: Task<Void, Never>?
  private var canWrite = false
  private var acceptingSessions = true
  private static let enabledKey = "usageStatsEnabled"

  init(defaults: UserDefaults = .standard, url: URL = UsageStatsStore.defaultURL) {
    self.defaults = defaults
    store = UsageStatsStore(url: url)
    enabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
    pending = Task { [weak self] in
      guard let self else { return }
      do {
        data = try await store.load()
        canWrite = true
      } catch {
        storageError = "Usage stats couldn’t be loaded. Existing data has been preserved. Clear Stats to start fresh."
      }
      isLoaded = true
    }
  }

  func setEnabled(_ value: Bool) {
    guard value != enabled else { return }
    enabled = value
    defaults.set(value, forKey: Self.enabledKey)
    invalidateSessions()
  }

  func begin() -> UsageSession? {
    guard enabled, acceptingSessions else { return nil }
    let session = UsageSession(generation: generation)
    active.insert(session)
    return session
  }

  func discard(_ session: UsageSession) { active.remove(session) }

  func complete(_ session: UsageSession, words: Int, recordingSeconds: Double, at date: Date) {
    guard enabled, session.generation == generation, active.remove(session) != nil,
      words >= 0 else { return }
    let day = UsageCalendar.dayKey(date)
    let previous = pending
    pending = Task { [weak self] in
      await previous?.value
      guard let self, enabled, session.generation == generation, canWrite else { return }
      var updated = data
      do {
        guard updated.days[day, default: UsageTotals()].add(
          words: words, recordingSeconds: recordingSeconds
        ) else { throw UsageStatsStore.StoreError.unsupportedOrInvalidData }
        try await store.save(updated)
        data = updated
        storageError = nil
      } catch {
        storageError = "Usage stats couldn’t be saved. Existing totals are unchanged; dictation is unaffected."
      }
    }
  }

  func clear() {
    invalidateSessions()
    let previous = pending
    pending = Task { [weak self] in
      await previous?.value
      guard let self else { return }
      do {
        try await store.clear()
        data = UsageStatsData()
        canWrite = true
        storageError = nil
      } catch {
        storageError = "Usage stats couldn’t be cleared. Your existing totals are still available."
      }
    }
  }

  func waitForPendingWrites() async { await pending?.value }

  func finishPendingOperationsForTermination() async {
    acceptingSessions = false
    active.removeAll()
    await pending?.value
  }

  private func invalidateSessions() {
    generation = UUID()
    active.removeAll()
  }
}

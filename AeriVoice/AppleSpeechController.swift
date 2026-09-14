import Combine
import Foundation
import Speech

@MainActor
protocol AppleSpeechAssetManaging {
  var isAvailable: Bool { get }
  func supportedLocales() async -> [Locale]
  func equivalentLocale(_ locale: Locale) async -> Locale?
  func installed(_ locale: Locale) async throws -> Bool
  func download(_ locale: Locale, progress: @escaping @MainActor (Double) -> Void) async throws
}

@MainActor
struct SystemAppleSpeechAssets: AppleSpeechAssetManaging {
  var isAvailable: Bool { SpeechTranscriber.isAvailable }
  func supportedLocales() async -> [Locale] { await SpeechTranscriber.supportedLocales }
  func equivalentLocale(_ locale: Locale) async -> Locale? {
    await SpeechTranscriber.supportedLocale(equivalentTo: locale)
  }
  func installed(_ locale: Locale) async throws -> Bool {
    // installedLocales describes shared files; status also requires this app's
    // reservation. Reserve only files already present, never request a download.
    guard await SpeechTranscriber.installedLocales.contains(where: {
      $0.identifier(.bcp47) == locale.identifier(.bcp47)
    }) else { return false }
    try await reserve(locale)
    return await AssetInventory.status(forModules: [SpeechTranscriber(locale: locale, preset: .progressiveTranscription)]) == .installed
  }
  private func reserve(_ locale: Locale) async throws {
    let reserved = await AssetInventory.reservedLocales
    guard !reserved.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) else { return }
    // Retain previously used languages for offline switching while capacity permits.
    if reserved.count >= AssetInventory.maximumReservedLocales, let old = reserved.first {
      _ = await AssetInventory.release(reservedLocale: old)
    }
    _ = try await AssetInventory.reserve(locale: locale)
  }

  func download(_ locale: Locale, progress: @escaping @MainActor (Double) -> Void) async throws {
    try AppNetworkPolicy.shared.checkAllowed()
    try await reserve(locale)
    let module = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
    guard let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) else { return }
    let observer = Task { @MainActor in
      while !Task.isCancelled {
        progress(request.progress.fractionCompleted)
        try? await Task.sleep(for: .milliseconds(200))
      }
    }
    defer { observer.cancel() }
    try await request.downloadAndInstall()
    progress(1)
  }
}

/// Asset installation is system managed. Switching models does not cancel it;
/// keep tracking the request until Apple's downloadAndInstall actually returns.
@MainActor
final class AppleSpeechController: ObservableObject {
  static let shared = AppleSpeechController()
  enum State: Equatable {
    case unavailable(String), missing, preparing, ready, downloading(Double), failed(String)
  }
  @Published private(set) var state: State = .missing
  @Published private(set) var supportedLocales: [Locale] = []
  @Published private(set) var suggestedLocaleIdentifier: String?
  @Published private(set) var localeIdentifier = ""
  @Published private(set) var assetsInstalled = false
  @Published private(set) var isDownloading = false
  var isReady: Bool { selected && assetsInstalled && state == .ready }
  private let assets: any AppleSpeechAssetManaging
  private let preferredLanguages: [String]
  private var selected = false
  private var generation = UUID()
  private var preparation: Task<Void, Never>?
  private var downloadTask: Task<Void, Never>?

  init(assets: any AppleSpeechAssetManaging = SystemAppleSpeechAssets(),
       preferredLanguages: [String] = Locale.preferredLanguages) {
    self.assets = assets
    self.preferredLanguages = preferredLanguages
  }

  func select(_ selected: Bool, localeIdentifier: String) {
    self.selected = selected
    self.localeIdentifier = localeIdentifier
    refresh()
  }

  func prepareIfNeeded() {
    guard !isReady, preparation == nil else { return }
    refresh()
  }

  func waitForPreparation() async {
    while let task = preparation { await task.value }
  }

  private func refresh() {
    generation = UUID()
    let id = generation
    let previous = preparation
    previous?.cancel()
    assetsInstalled = false
    if !isDownloading { state = .preparing }
    preparation = Task { @MainActor [self] in
      defer { if generation == id { preparation = nil } }
      await previous?.value
      guard generation == id, !Task.isCancelled else { return }
      guard assets.isAvailable else {
        if !isDownloading { state = .unavailable("Apple Speech is unavailable on this Mac.") }
        return
      }
      let locales = await assets.supportedLocales()
      guard generation == id else { return }
      supportedLocales = locales.sorted { $0.identifier < $1.identifier }
      // Only the user's primary Mac language determines the suggestion.
      let suggestion: Locale?
      if let first = preferredLanguages.first {
        suggestion = await assets.equivalentLocale(Locale(identifier: first))
      } else { suggestion = nil }
      guard generation == id else { return }
      suggestedLocaleIdentifier = suggestion?.identifier
      let requested = localeIdentifier.isEmpty ? suggestion : Locale(identifier: localeIdentifier)
      guard let requested, let locale = await assets.equivalentLocale(requested) else {
        guard generation == id else { return }
        if !isDownloading { state = .unavailable("Choose a supported Apple Speech language.") }
        return
      }
      guard generation == id else { return }
      localeIdentifier = locale.identifier
      do {
        let installed = try await assets.installed(locale)
        guard generation == id else { return }
        assetsInstalled = installed
        if !isDownloading { state = installed ? .ready : .missing }
      } catch {
        guard generation == id else { return }
        if !isDownloading { state = .failed(error.localizedDescription) }
      }
    }
  }

  func download() {
    guard !isDownloading, !localeIdentifier.isEmpty,
          supportedLocales.contains(where: { $0.identifier == localeIdentifier }) else { return }
    let locale = Locale(identifier: localeIdentifier)
    isDownloading = true
    state = .downloading(0)
    downloadTask = Task { @MainActor [self] in
      do {
        try await assets.download(locale) { [weak self] value in
          guard let self, self.isDownloading else { return }
          self.state = .downloading(min(1, max(0, value)))
        }
        isDownloading = false
        downloadTask = nil
        refresh()
      } catch {
        isDownloading = false
        downloadTask = nil
        state = .failed(error.localizedDescription)
      }
    }
  }
}

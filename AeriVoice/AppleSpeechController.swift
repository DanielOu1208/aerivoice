import Combine
import Foundation
import Speech
import OSLog

@MainActor
protocol AppleSpeechAssetManaging {
  var isAvailable: Bool { get }
  func supportedLocales() async -> [Locale]
  func equivalentLocale(_ locale: Locale) async -> Locale?
  func installed(_ locale: Locale) async throws -> Bool
  func download(_ locale: Locale, progress: @escaping @MainActor (Double) -> Void) async throws
}

@MainActor
struct AppleSpeechReservations {
  var reserveLocale: (Locale) async throws -> Bool = { try await AssetInventory.reserve(locale: $0) }
  var reservedLocales: () async -> [Locale] = { await AssetInventory.reservedLocales }
  var releaseLocale: (Locale) async -> Bool = { await AssetInventory.release(reservedLocale: $0) }

  func reserve(_ locale: Locale) async throws {
    do {
      // Apple may return a different locale variant for the same backing assets.
      // Let the system recognize existing reservations before making room.
      _ = try await reserveLocale(locale)
    } catch let error as SFSpeechError where error.code == .tooManyAssetLocalesAllocated {
      guard let old = await reservedLocales().first else { throw error }
      _ = await releaseLocale(old)
      _ = try await reserveLocale(locale)
    }
  }
}

@MainActor
struct SystemAppleSpeechAssets: AppleSpeechAssetManaging {
  var moduleStatus: (SpeechTranscriber) async -> AssetInventory.Status = {
    await AssetInventory.status(forModules: [$0])
  }
  var installedLocales: () async -> [Locale] = { await SpeechTranscriber.installedLocales }
  var reservations = AppleSpeechReservations()
  var isAvailable: Bool { SpeechTranscriber.isAvailable }
  func supportedLocales() async -> [Locale] { await SpeechTranscriber.supportedLocales }
  func equivalentLocale(_ locale: Locale) async -> Locale? {
    await SpeechTranscriber.supportedLocale(equivalentTo: locale)
  }
  func installed(_ locale: Locale) async throws -> Bool {
    let module = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
    // The module's status is authoritative after installation. The shared locale
    // list can lag behind a completed request and must not turn Ready into Missing.
    let initialStatus = await moduleStatus(module)
    trace(module, phase: "initial", status: initialStatus)
    if initialStatus == .installed { return true }
    // installedLocales describes shared files; status also requires this app's
    // reservation. Reserve only files already present, never request a download.
    let locales = await installedLocales()
    trace("installed locales: \(locales.map(\.identifier))")
    guard locales.contains(where: {
      $0.identifier(.bcp47) == locale.identifier(.bcp47)
    }) else { return false }
    try await reservations.reserve(locale)
    let reservedStatus = await moduleStatus(module)
    trace(module, phase: "reserved", status: reservedStatus)
    return reservedStatus == .installed
  }
  func download(_ locale: Locale, progress: @escaping @MainActor (Double) -> Void) async throws {
    try AppNetworkPolicy.shared.checkAllowed()
    try await reservations.reserve(locale)
    let module = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
    guard let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) else {
      progress(1)
      return
    }
    let observer = Task { @MainActor in
      while !Task.isCancelled {
        progress(request.progress.fractionCompleted)
        try? await Task.sleep(for: .milliseconds(200))
      }
    }
    defer { observer.cancel() }
    try await request.downloadAndInstall()
    let status = await moduleStatus(module)
    trace(module, phase: "download finished", status: status)
    progress(1)
  }

  private func trace(_ module: SpeechTranscriber, phase: String, status: AssetInventory.Status) {
    let classification: String
    switch status {
    case .installed: classification = "installed"
    case .supported: classification = "supported"
    case .downloading: classification = "downloading"
    case .unsupported: classification = "unsupported"
    @unknown default: classification = "unknown"
    }
    trace("\(phase): locales=\(module.selectedLocales.map(\.identifier)), status=\(String(describing: status)), case=\(classification), equalsInstalled=\(status == .installed)")
  }

  private func trace(_ message: String) {
    guard UserDefaults.standard.bool(forKey: "AeriVoiceSpeechAssetTrace") else { return }
    Logger(subsystem: "com.danielou.AeriVoice", category: "AppleSpeechAssets").notice("\(message, privacy: .public)")
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

  private func refresh(afterDownloading downloadedLocale: Locale? = nil) {
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
        if !isDownloading {
          if installed {
            state = .ready
          } else if downloadedLocale?.identifier(.bcp47) == locale.identifier(.bcp47) {
            state = .failed("Apple finished the download attempt, but this language is not ready yet. Check installed language support or retry the download.")
          } else {
            state = .missing
          }
        }
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
    let previous = preparation
    downloadTask = Task { @MainActor [self] in
      // Finish any readiness/reservation check before installing the same assets.
      await previous?.value
      do {
        try await assets.download(locale) { [weak self] value in
          guard let self, self.isDownloading else { return }
          self.state = .downloading(min(1, max(0, value)))
        }
        isDownloading = false
        downloadTask = nil
        refresh(afterDownloading: locale)
      } catch {
        isDownloading = false
        downloadTask = nil
        state = .failed(error.localizedDescription)
      }
    }
  }
}

import Combine
import Foundation

protocol LocalModelAssetManaging: Actor {
  func isInstalled() async -> Bool
  func hasPartialDownload() async -> Bool
  func verifiedDirectory() async throws -> URL
  func download(progress: @escaping @Sendable (Double) -> Void) async throws -> URL
  func remove() async throws
}

extension LocalModelAssets: LocalModelAssetManaging {}

@MainActor
final class LocalModelController: ObservableObject {
  static let shared = LocalModelController()
  enum State: Equatable {
    case missing, partial, available, preparing, removing, ready, downloading(Double), failed(String)
  }
  @Published private(set) var state: State = .missing
  let runtime: LocalSpeechRuntime
  private let assets: any LocalModelAssetManaging
  private var selected = false
  private var transition: Task<Void, Never>?
  private var downloadTask: Task<Void, Never>?
  private var isRemoving = false
  private var pressure: DispatchSourceMemoryPressure?
  var assetsInstalled: Bool {
    switch state {
    case .available, .preparing, .ready: true
    default: false
    }
  }
  var isDownloading: Bool { downloadTask != nil }
  var isReady: Bool { state == .ready && runtime.isReady }
  var canRemove: Bool { !isRemoving && !runtime.hasActiveSession && state != .preparing }

  init(assets: any LocalModelAssetManaging = LocalModelAssets(),
       runtime: LocalSpeechRuntime = LocalSpeechRuntime(), observeMemoryPressure: Bool = true) {
    self.assets = assets
    self.runtime = runtime
    guard observeMemoryPressure else { return }
    let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
    source.setEventHandler { [weak self] in
      Task { @MainActor in self?.releaseForPressure() }
    }
    source.resume()
    pressure = source
  }

  func select(_ selected: Bool) {
    self.selected = selected
    schedulePreparation()
  }

  func waitForPreparation() async { await transition?.value }

  func prepareIfNeeded() {
    guard selected, !isReady, state != .preparing, downloadTask == nil else { return }
    schedulePreparation()
  }

  private func schedulePreparation() {
    let previous = transition
    previous?.cancel()
    transition = Task { @MainActor [weak self] in
      await previous?.value
      guard let self, !Task.isCancelled else { return }
      if !self.selected {
        await self.runtime.unload()
        let state = await self.downloadedState()
        guard !Task.isCancelled, self.downloadTask == nil else { return }
        self.state = state
        return
      }
      guard self.downloadTask == nil else { return }
      let state = await self.downloadedState()
      guard !Task.isCancelled else { return }
      guard self.downloadTask == nil else { return }
      guard state == .available else { self.state = state; return }
      self.state = .preparing
      do {
        let directory = try await self.assets.verifiedDirectory()
        try await self.runtime.load(from: directory)
        guard !Task.isCancelled else { return }
        self.state = .ready
      } catch { if !Task.isCancelled { self.state = .failed(error.localizedDescription) } }
    }
  }

  func download() {
    guard downloadTask == nil, !isRemoving, !AppNetworkPolicy.shared.isOffline else { return }
    state = .downloading(0)
    downloadTask = Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        _ = try await self.assets.download { [weak self] progress in
          Task { @MainActor in
            guard self?.downloadTask != nil else { return }
            self?.state = .downloading(progress)
          }
        }
        self.state = .available
      } catch {
        if Task.isCancelled || error is CancellationError {
          // Inventory must run outside the cancelled task to recognize installed files too.
          self.state = await Task { await self.downloadedState() }.value
        }
        else { self.state = .failed(error.localizedDescription) }
      }
      self.downloadTask = nil
      if self.selected, self.state == .available { self.schedulePreparation() }
    }
  }

  func cancelDownload() { downloadTask?.cancel() }

  func cancelDownloadAndWait() async {
    downloadTask?.cancel()
    await downloadTask?.value
  }

  func remove() {
    guard canRemove, downloadTask == nil else { return }
    isRemoving = true
    state = .removing
    let previous = transition
    previous?.cancel()
    transition = Task { @MainActor [weak self] in
      await previous?.value
      guard let self else { return }
      defer { self.isRemoving = false }
      await self.runtime.unload()
      do { try await self.assets.remove(); self.state = .missing }
      catch { self.state = .failed(error.localizedDescription) }
    }
  }

  func releaseForPressure() {
    guard !isRemoving else { return } // Removal already unloads the runtime.
    let previous = transition
    previous?.cancel()
    if downloadTask == nil { state = .available }
    transition = Task { @MainActor [weak self] in
      await previous?.value
      guard let self, !Task.isCancelled else { return }
      await self.runtime.unload()
      guard !Task.isCancelled else { return }
      let state = await self.downloadedState()
      guard !Task.isCancelled else { return }
      if self.downloadTask == nil { self.state = state }
    }
  }

  private func downloadedState() async -> State {
    if await assets.isInstalled() { return .available }
    return await assets.hasPartialDownload() ? .partial : .missing
  }
}

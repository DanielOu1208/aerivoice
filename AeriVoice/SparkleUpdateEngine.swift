#if AERIVOICE_APP
import Foundation
import Sparkle

/// A reply belongs to one Sparkle stage. Consuming it before invocation makes
/// reentrant teardown and late callbacks from a dismissed window harmless.
@MainActor
final class UpdateReply<Value> {
  private var callback: ((Value) -> Void)?
  init(_ callback: @escaping (Value) -> Void) { self.callback = callback }
  @discardableResult func resolve(_ value: Value, before: () -> Void = {}) -> Bool {
    guard let callback else { return false }
    self.callback = nil
    before()
    callback(value)
    return true
  }
  func invalidate() { callback = nil }
}

@MainActor
final class SparkleUpdateEngine: NSObject, UpdateEngine, SPUUpdaterDelegate {
  var onEvent: ((UpdateEngineEvent) -> Void)?
  var allowsNetwork: (() -> Bool)?
  var allowsPresentation: (() -> Bool)?
  private lazy var driver = SparkleUserDriver(hostBundle: hostBundle)
  private lazy var updater = SPUUpdater(hostBundle: hostBundle, applicationBundle: hostBundle,
                                       userDriver: driver, delegate: self)
  private let hostBundle: Bundle
  private var observations: [NSKeyValueObservation] = []
  private var started = false
  // Sparkle's sessionInProgress also covers schedule-only probes which never
  // send didFinishUpdateCycle. Only cancel a requested/started check.
  private var checkRequested = false

  init(hostBundle: Bundle = .main) {
    self.hostBundle = hostBundle
    super.init()
    driver.emit = { [weak self] in self?.onEvent?($0) }
    driver.presentationAllowed = { [weak self] in self?.allowsPresentation?() ?? false }
    driver.networkAllowed = { [weak self] in self?.allowsNetwork?() ?? false }
  }

  var automaticallyChecks: Bool {
    get { updater.automaticallyChecksForUpdates }
    set { updater.automaticallyChecksForUpdates = newValue }
  }
  var canCheck: Bool { started && updater.canCheckForUpdates }

  func start() throws {
    guard !started else { return }
    updater.automaticallyDownloadsUpdates = false
    updater.sendsSystemProfile = false
    try updater.start()
    started = true
    observations = [
      updater.observe(\.automaticallyChecksForUpdates) { [weak self] _, _ in
        Task { @MainActor in self?.onEvent?(.settingsChanged) }
      },
      updater.observe(\.canCheckForUpdates) { [weak self] _, _ in
        Task { @MainActor in self?.onEvent?(.settingsChanged) }
      }
    ]
  }

  func checkForUpdates(showProgress: Bool) {
    guard started, updater.canCheckForUpdates, allowsNetwork?() == true else { return }
    checkRequested = true
    driver.showsCheckingProgress = showProgress
    updater.checkForUpdates()
  }
  func resumeDeferredPresentation() { driver.resumeDeferredPresentation() }
  func cancelCurrentCycle() {
    guard checkRequested else { return }
    driver.cancelCurrentCycle()
  }
  func settingsChanged() {
    if started { updater.resetUpdateCycle() }
    onEvent?(.settingsChanged)
  }

  func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
    guard allowsNetwork?() == true, !driver.cancelledByApp else { throw CancellationError() }
    checkRequested = true
    driver.beginCycle()
  }
  func updater(_ updater: SPUUpdater, shouldProceedWithUpdate updateItem: SUAppcastItem,
               updateCheck: SPUUpdateCheck) throws {
    guard allowsNetwork?() == true, !driver.cancelledByApp else { throw CancellationError() }
  }
  func updater(_ updater: SPUUpdater, didFinishLoading appcast: SUAppcast) {
    onEvent?(.feedLoaded)
  }
  func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
    guard allowsNetwork?() == true, !driver.cancelledByApp else { return }
    onEvent?(.notFound(error.localizedDescription))
  }
  func updater(_ updater: SPUUpdater, shouldDownloadReleaseNotesForUpdate updateItem: SUAppcastItem) -> Bool { false }
  func updaterWillRelaunchApplication(_ updater: SPUUpdater) { onEvent?(.restartRequested) }
  func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
    checkRequested = false
    let message = driver.cancelledByApp ? nil : error?.localizedDescription
    driver.finishCycle()
    onEvent?(.cycleFinished(error: message))
  }
}
#endif

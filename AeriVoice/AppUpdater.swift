import Combine
import Foundation

/// Application policy only. Sparkle owns discovery, signatures, downloads and installation.
@MainActor
final class AppUpdater: ObservableObject {
  @Published private(set) var stage: UpdateStage = .idle
  @Published private(set) var availableUpdate: AvailableUpdate?
  @Published private(set) var automaticallyChecks: Bool
  @Published private(set) var showsAlerts: Bool
  @Published private(set) var lastSuccessfulCheck: Date?
  @Published private(set) var message: String?
  @Published private(set) var restartPending = false

  private enum Key {
    static let alerts = "showUpdateAlerts"
    static let lastCheck = "lastSuccessfulUpdateCheck"
    static let alertBuild = "lastUpdateAlertBuild"
    static let alertDate = "lastUpdateAlertDate"
    static let dialogBuild = "lastUpdateDialogBuild"
    static let dialogDate = "lastUpdateDialogDate"
    static let snoozedBuild = "snoozedUpdateBuild"
    static let snoozedDate = "snoozedUpdateDate"
    static let permissionRequested = "updateNotificationPermissionRequested"
  }

  private let engine: (any UpdateEngine)?
  private let notifications: any UpdateNotifying
  private let defaults: UserDefaults
  private let now: () -> Date
  private var started = false
  private var setupComplete = false
  private var offline = true
  private var changingOffline = false
  private var dictationIdle = false
  private var settingsActive = false
  private var cycleActive = false
  private var automaticSettingsCheck = false
  private var offlineRequested = false
  private var deferredUserCheck = false
  private var offlineWaiters: [CheckedContinuation<Void, Never>] = []
  private var alertTask: Task<Void, Never>?
  private var alertGeneration = UUID()

  init(engine: (any UpdateEngine)? = AppUpdater.makeEngine(),
       notifications: any UpdateNotifying = UpdateNotifications(),
       defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
    self.engine = engine
    self.notifications = notifications
    self.defaults = defaults
    self.now = now
    automaticallyChecks = engine?.automaticallyChecks ?? true
    showsAlerts = defaults.object(forKey: Key.alerts) as? Bool ?? true
    lastSuccessfulCheck = defaults.object(forKey: Key.lastCheck) as? Date
    engine?.allowsNetwork = { [weak self] in self?.networkAllowed == true }
    engine?.allowsPresentation = { [weak self] in self?.presentationAllowed == true }
    engine?.onEvent = { [weak self] event in self?.receive(event) }
  }

  var isEnabled: Bool { engine != nil }
  var canCheck: Bool { started && networkAllowed && dictationIdle && !restartPending && engine?.canCheck == true }
  var canEnterOffline: Bool { !stage.preventsOfflineTransition && !restartPending }
  var menuTitle: String { availableUpdate == nil ? "Check for Updates…" : "Update Available…" }
  var installedVersion: String {
    let info = Bundle.main.infoDictionary ?? [:]
    let version = info["AeriVoiceReleaseVersion"] as? String
      ?? info["CFBundleShortVersionString"] as? String ?? "Unknown"
    let build = info["CFBundleVersion"] as? String ?? "Unknown"
    return "\(version) (\(build))"
  }
  var status: String {
    if !isEnabled { return "Updates are available in distribution builds." }
    if changingOffline || offlineRequested {
      return stage.preventsOfflineTransition
        ? "Finish or cancel update preparation to switch modes."
        : "Switching to Offline… Waiting for update activity to finish."
    }
    if offline { return "Turn off Offline mode to check for updates." }
    if restartPending { return "Finishing dictation before restarting…" }
    switch stage {
    case .checking: return "Checking for updates…"
    case .downloading: return "Downloading update…"
    case .preparing: return "Preparing update…"
    case .readyToInstall: return "Update ready to install."
    case .installing: return "Installing update…"
    case .idle, .offering: break
    }
    if let availableUpdate { return "Version \(availableUpdate.version) is available." }
    return message ?? "Check for the latest version of AeriVoice."
  }

  private var networkAllowed: Bool {
    setupComplete && !offline && !changingOffline && !offlineRequested && !restartPending
  }
  private var presentationAllowed: Bool {
    networkAllowed && dictationIdle && (!automaticSettingsCheck || settingsActive)
  }

  func updateContext(setupComplete: Bool, offline: Bool, changingOffline: Bool, dictationIdle: Bool) {
    let wasNetworkAllowed = networkAllowed
    self.setupComplete = setupComplete
    self.offline = offline
    self.changingOffline = changingOffline
    self.dictationIdle = dictationIdle
    if !changingOffline && !cycleActive { offlineRequested = false }
    if !networkAllowed { invalidateAlerts() }
    if setupComplete && !started && networkAllowed { start() }
    if networkAllowed && !wasNetworkAllowed && started { engine?.settingsChanged() }
    objectWillChange.send()
    if presentationAllowed {
      requestNotificationPermissionIfAppropriate()
      engine?.resumeDeferredPresentation()
      if deferredUserCheck {
        deferredUserCheck = false
        checkForUpdates()
      } else { surfaceAvailableUpdate() }
    }
  }

  private func start() {
    guard let engine else { return }
    do {
      try engine.start()
      started = true
      automaticallyChecks = engine.automaticallyChecks
      message = nil
    } catch { message = "Updates couldn’t start: \(error.localizedDescription)" }
  }

  func setAutomaticallyChecks(_ value: Bool) {
    guard let engine else { return }
    engine.automaticallyChecks = value
    automaticallyChecks = value
    if !value { invalidateAlerts() }
  }

  func setShowsAlerts(_ value: Bool) {
    showsAlerts = value
    defaults.set(value, forKey: Key.alerts)
    invalidateAlerts()
    if value { requestNotificationPermissionIfAppropriate(); surfaceAvailableUpdate() }
  }

  func checkForUpdates() {
    checkForUpdates(automaticallyFromSettings: false)
  }

  private func checkForUpdates(automaticallyFromSettings: Bool) {
    guard canCheck else { return }
    invalidateAlerts()
    message = nil
    cycleActive = true
    automaticSettingsCheck = automaticallyFromSettings
    engine?.checkForUpdates(showProgress: !automaticallyFromSettings)
  }

  /// A notification may be old; let Sparkle revalidate the current feed and version.
  func openUpdateFromNotification() {
    guard networkAllowed else { return }
    if dictationIdle { checkForUpdates() }
    else { deferredUserCheck = true }
  }

  func setSettingsActive(_ active: Bool) {
    settingsActive = active
    if !active && automaticSettingsCheck {
      engine?.cancelCurrentCycle()
    }
    if active {
      requestNotificationPermissionIfAppropriate()
      surfaceAvailableUpdate()
    }
  }

  private func requestNotificationPermissionIfAppropriate() {
    guard settingsActive, setupComplete, automaticallyChecks, showsAlerts, dictationIdle,
      !defaults.bool(forKey: Key.permissionRequested) else { return }
    defaults.set(true, forKey: Key.permissionRequested)
    Task { [weak self] in
      guard let self else { return }
      await notifications.requestPermission()
      surfaceAvailableUpdate()
    }
  }

  func prepareForOffline() async {
    offlineRequested = true
    deferredUserCheck = false
    invalidateAlerts()
    engine?.cancelCurrentCycle()
    guard cycleActive else { return }
    await withCheckedContinuation { offlineWaiters.append($0) }
  }

  /// Also called by the termination boundary, covering Sparkle paths which skip
  /// its postponement hook. The coordinator itself enforces the admission gate.
  func beginRestart() {
    restartPending = true
    invalidateAlerts()
  }

  private func receive(_ event: UpdateEngineEvent) {
    switch event {
    case .stage(let next):
      stage = next
      if next != .idle { cycleActive = true }
    case .feedLoaded:
      lastSuccessfulCheck = now()
      defaults.set(lastSuccessfulCheck, forKey: Key.lastCheck)
      message = nil
    case .found(let update, let userInitiated):
      availableUpdate = update
      if userInitiated {
        invalidateAlerts()
        defaults.set(update.build, forKey: Key.dialogBuild)
        defaults.set(now(), forKey: Key.dialogDate)
      }
    case .presentingOffer:
      // The native offer now owns the user's attention. Its window becoming key
      // must not cancel it when Settings resigns key in the same application.
      automaticSettingsCheck = false
    case .notFound(let explanation):
      availableUpdate = nil
      message = explanation
      invalidateAlerts()
    case .choice(let choice, let update):
      invalidateAlerts()
      if choice == .skip { availableUpdate = nil }
      // A real choice, unlike dismissing an internal discovery, snoozes alerts.
      recordAlert(update)
      defaults.set(update.build, forKey: Key.snoozedBuild)
      defaults.set(now(), forKey: Key.snoozedDate)
    case .restartRequested:
      beginRestart()
    case .cycleFinished(let error):
      cycleActive = false
      automaticSettingsCheck = false
      if error != nil { restartPending = false }
      if !restartPending { stage = .idle }
      if let error, networkAllowed { message = error }
      let waiters = offlineWaiters
      offlineWaiters.removeAll()
      for waiter in waiters { waiter.resume() }
      surfaceAvailableUpdate()
    case .settingsChanged:
      automaticallyChecks = engine?.automaticallyChecks ?? automaticallyChecks
      objectWillChange.send()
      surfaceAvailableUpdate()
    }
  }

  private func alertIsDue(_ update: AvailableUpdate) -> Bool {
    reminderIsDue(update, buildKey: Key.alertBuild, dateKey: Key.alertDate)
  }

  private func reminderIsDue(_ update: AvailableUpdate, buildKey: String, dateKey: String) -> Bool {
    guard defaults.string(forKey: buildKey) == update.build,
      let last = defaults.object(forKey: dateKey) as? Date else { return true }
    let elapsed = now().timeIntervalSince(last)
    return elapsed >= 86_400 || elapsed < 0
  }

  private func recordAlert(_ update: AvailableUpdate) {
    defaults.set(update.build, forKey: Key.alertBuild)
    defaults.set(now(), forKey: Key.alertDate)
  }

  private func invalidateAlerts() {
    alertGeneration = UUID()
    alertTask?.cancel()
    // Keep the task until its pending OS request settles. Otherwise an old
    // completion could clear a newer notification with the same identifier.
    notifications.clear()
  }

  private func surfaceAvailableUpdate() {
    guard presentationAllowed, automaticallyChecks, showsAlerts, !cycleActive,
      let update = availableUpdate else { return }
    // Opening Settings makes the pending notification actionable even if the
    // notification was sent earlier, but Later/Skip must still snooze the dialog.
    if settingsActive, canCheck,
      reminderIsDue(update, buildKey: Key.dialogBuild, dateKey: Key.dialogDate),
      reminderIsDue(update, buildKey: Key.snoozedBuild, dateKey: Key.snoozedDate) {
      defaults.set(update.build, forKey: Key.dialogBuild)
      defaults.set(now(), forKey: Key.dialogDate)
      recordAlert(update)
      checkForUpdates(automaticallyFromSettings: true)
      return
    }
    guard alertIsDue(update), alertTask == nil else { return }
    let generation = alertGeneration
    alertTask = Task { [weak self] in
      guard let self else { return }
      let posted = await notifications.post(update)
      guard !Task.isCancelled, generation == alertGeneration, presentationAllowed,
        showsAlerts, automaticallyChecks, !cycleActive, availableUpdate == update else {
        notifications.clear()
        alertTask = nil
        surfaceAvailableUpdate()
        return
      }
      if posted { recordAlert(update) }
      alertTask = nil
    }
  }

  static func makeEngine() -> (any UpdateEngine)? {
    #if AERIVOICE_APP && (AERIVOICE_DISTRIBUTION || AERIVOICE_UPDATER_QA)
      if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
        return SparkleUpdateEngine()
      }
    #endif
    return nil
  }
}

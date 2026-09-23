import AVFoundation
import AppKit
import Combine

enum CredentialStatus: Equatable {
  case missing
  case saved
  case validating
  case error(String)
}

enum OnboardingFinishResult: Equatable {
  case completed
  case incomplete
  case loginItemFailed
}

enum MicrophonePermissionAction: Equatable {
  case request
  case openSettings
  case none

  init(status: AVAuthorizationStatus) {
    switch status {
    case .notDetermined: self = .request
    case .authorized: self = .none
    case .denied, .restricted: self = .openSettings
    @unknown default: self = .openSettings
    }
  }

  var title: String {
    switch self {
    case .request: "Allow Microphone"
    case .openSettings: "Open Settings"
    case .none: "Allowed"
    }
  }
}

@MainActor
final class AppModel: ObservableObject {
  let localModel = LocalModelController.shared
  let appleSpeech = AppleSpeechController.shared
  @Published private(set) var changingOfflineMode = false
  @Published var localSetupRequested = false
  @Published var shortcutCaptureRequest: UUID?
  @Published var capturesModifierSides = false
  private var capturingShortcut = false
  let preferences: AppPreferences
  let usageStats: UsageStatsModel
  let coordinator: DictationCoordinator
  let credentialManager: CredentialManager
  let benchmarkRecorder: LatencyBenchmarkRecorder
  let runtimeDiagnostics: RuntimeDiagnosticsRecorder

  @Published var shortcutConfirmation: ShortcutDefinition?
  @Published var permissionRefresh = 0
  @Published var settingsDestinationRequest: SettingsDestination?
  let settingsWindowWillClose = PassthroughSubject<Void, Never>()

  private let shortcutMonitor = GlobalShortcutMonitor()
  private var cancellables = Set<AnyCancellable>()
  private lazy var grokPreparation = GrokPreparationController(
    initiallyLocked: true,
    eligible: { [weak self] in
      guard let self else { return false }
      return self.preferences.onboardingComplete && !self.preferences.offlineMode
        && !self.changingOfflineMode && !self.coordinator.canCancel
        && self.preferences.effectiveTranscriptionProvider == .grok
        && self.credentialManager.status(for: .xai) == .saved
    },
    prepare: { [weak self] in await self?.coordinator.prepareTranscriptionConnection() ?? false },
    discard: { [weak self] in self?.coordinator.invalidatePreparedConnection() })

  init(launchStartedMS: Double = DiagnosticsClock.uptimeMS()) {
    let preferences = AppPreferences()
    let credentials = KeychainStore()
    #if AERIVOICE_DISTRIBUTION
      let legacyCredentials: KeychainStore? = KeychainStore(
        namespace: .legacyRelease, authenticationPolicy: .allow)
    #else
      let legacyCredentials: KeychainStore? = nil
    #endif
    let credentialManager = CredentialManager(
      store: credentials, legacyStore: legacyCredentials)
    let writer = DiagnosticsWriteQueue(directoryURL: LatencyBenchmarkStore.defaultDirectoryURL)
    let environment = BenchmarkEnvironment.live
    let runtime = RuntimeDiagnosticsRecorder(
      enabled: preferences.latencyLogging, writer: writer, launchStartedMS: launchStartedMS,
      environment: environment, settings: { DiagnosticSettings(preferences) })
    let benchmarkRecorder = LatencyBenchmarkRecorder(
      environment: environment, enabled: preferences.latencyLogging,
      recordingGeneration: preferences.diagnosticsGeneration,
      acceptLegacyCheckpoint: preferences.acceptsLegacyDiagnosticCheckpoint,
      writer: writer, runtime: runtime)
    let usageStats = UsageStatsModel()
    self.usageStats = usageStats
    self.preferences = preferences
    self.credentialManager = credentialManager
    self.benchmarkRecorder = benchmarkRecorder
    self.runtimeDiagnostics = runtime
    coordinator = DictationCoordinator(
      preferences: preferences, credentials: credentials, benchmark: benchmarkRecorder,
      usageStats: usageStats,
      runtimeDiagnostics: runtime,
      localReadiness: {
        if preferences.localTranscriptionModel == .apple {
          let controller = AppleSpeechController.shared
          if !controller.isReady { controller.prepareIfNeeded() }
          return controller.isReady
        }
        let controller = LocalModelController.shared
        if !controller.isReady { controller.prepareIfNeeded() }
        return controller.isReady
      })
    preferences.onDiagnosticsLoggingChange = { [weak benchmarkRecorder, weak preferences] enabled in
      benchmarkRecorder?.setEnabled(
        enabled, recordingGeneration: preferences?.diagnosticsGeneration)
    }
    capturesModifierSides = preferences.shortcut?.distinguishesModifierSides == true
    preferences.onTranscriptionProviderChange = { [weak self] in
      self?.grokPreparation.invalidate()
      self?.prewarmTranscription()
    }
    preferences.onVocabularyChange = { [weak self] in self?.grokConfigurationChanged() }
    credentialManager.onCredentialChange = { [weak self] kind in
      if kind == .xai { self?.grokConfigurationChanged() }
    }
    coordinator.onSuccessfulSessionCompletion = { [weak self] in self?.grokPreparation.request() }
    preferences.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
    preferences.objectWillChange
      .debounce(for: .milliseconds(50), scheduler: RunLoop.main)
      .sink { [weak runtime] in runtime?.settingsChanged() }
      .store(in: &cancellables)
    shortcutMonitor.onAvailabilityChange = { [weak runtime] in runtime?.shortcutAvailable($0) }
    localModel.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &cancellables)
    appleSpeech.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &cancellables)
    coordinator.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &cancellables)
    credentialManager.objectWillChange.sink { [weak self] in
      self?.objectWillChange.send()
    }.store(in: &cancellables)
    shortcutMonitor.onHoldPress = { [weak coordinator] in coordinator?.holdShortcutPressed() }
    shortcutMonitor.onPress = { [weak coordinator] in coordinator?.shortcutPressed() }
    shortcutMonitor.onHoldRelease = { [weak coordinator] lifecycleGeneration in
      coordinator?.finishHeldDictation(lifecycleGeneration: lifecycleGeneration)
    }
    shortcutMonitor.onCancel = { [weak coordinator] in coordinator?.cancel() }
    shortcutMonitor.shouldCancel = { [weak coordinator] in coordinator?.canCancel == true }
    preferences.$shortcut.combineLatest(preferences.$shortcutActivationMode)
      .sink { [weak self] definition, activationMode in
        guard let self, !self.capturingShortcut, !self.changingOfflineMode else { return }
        if let definition {
          self.shortcutMonitor.start(
            definition: definition, activationMode: activationMode)
        } else {
          self.shortcutMonitor.stop()
        }
      }
      .store(in: &cancellables)
    NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
      .sink { [weak self] _ in
        guard let self else { return }
        self.credentialManager.refreshStoredCredentials()
        self.refreshTranscriptionSessionEligibility()
        self.permissionRefresh += 1
        guard !self.capturingShortcut, !self.changingOfflineMode, AXIsProcessTrusted(), let shortcut = self.preferences.shortcut else { return }
        self.shortcutMonitor.start(
          definition: shortcut, activationMode: self.preferences.shortcutActivationMode)
      }
      .store(in: &cancellables)
  }

  var transcriptionReady: Bool {
    if let kind = preferences.effectiveTranscriptionProvider.credentialKind { return hasCredential(kind) }
    return selectedLocalModelReady
  }

  var onboardingReadiness: OnboardingReadiness {
    OnboardingReadiness.selectedProviders(
      preferences: preferences, hasCredential: hasCredential, hasPermissions: permissionsReady,
      localModelReady: selectedLocalModelReady)
  }

  var readinessComplete: Bool { onboardingReadiness.isComplete }

  var setupComplete: Bool { preferences.onboardingComplete && readinessComplete }

  func hasCredential(_ kind: CredentialKind) -> Bool {
    credentialManager.hasCredential(kind)
  }

  func credentialStatus(for kind: CredentialKind) -> CredentialStatus {
    credentialManager.status(for: kind)
  }

  func canImportLegacyCredential(_ kind: CredentialKind) -> Bool {
    credentialManager.canImportLegacyCredential(kind)
  }

  var permissionsReady: Bool {
    AVCaptureDevice.authorizationStatus(for: .audio) == .authorized && AXIsProcessTrusted()
  }

  func selectTranscriptionProvider(_ provider: TranscriptionProvider) {
    guard !coordinator.canCancel, !changingOfflineMode,
      provider != preferences.effectiveTranscriptionProvider else { return }
    if preferences.offlineMode, provider != .local {
      setOfflineMode(false, selecting: provider)
    } else {
      preferences.transcriptionProvider = provider
    }
  }

  func selectTranscriptionChoice(_ choice: TranscriptionChoice) {
    guard !coordinator.canCancel, !changingOfflineMode, !appleSpeech.isDownloading else { return }
    if let localModel = choice.localModel {
      let installed = localModel == .apple ? appleSpeech.assetsInstalled : self.localModel.assetsInstalled
      guard !preferences.offlineMode || installed else { return }
      setLocalTranscriptionModel(localModel)
    }
    selectTranscriptionProvider(choice.provider)
  }

  func setOfflineMode(_ enabled: Bool, selecting provider: TranscriptionProvider? = nil) {
    guard enabled != preferences.offlineMode, canChangeOfflineMode else { return }
    changingOfflineMode = true
    grokPreparation.invalidate()
    shortcutMonitor.stop()
    // Persist the restriction before asynchronous cancellation, including a possible quit.
    if enabled { preferences.setOfflineMode(true) }
    for kind in CredentialKind.allCases { credentialManager.cancelValidation(kind) }
    preferences.openRouterCatalog.cancelRefresh()
    Task { @MainActor in
      await AppNetworkPolicy.shared.setOffline(enabled)
      if enabled { await localModel.cancelDownloadAndWait() }
      else {
        // Restore network access before selecting a cloud provider. Keep controls
        // disabled until both preferences agree with the new mode.
        if let provider { preferences.transcriptionProvider = provider }
        preferences.setOfflineMode(false)
      }
      changingOfflineMode = false
      prewarmTranscription()
      if !capturingShortcut, let shortcut = preferences.shortcut {
        shortcutMonitor.start(definition: shortcut, activationMode: preferences.shortcutActivationMode)
      }
    }
  }

  func beginShortcutCapture() {
    capturingShortcut = true
    shortcutMonitor.stop()
  }

  func endShortcutCapture() {
    shortcutCaptureRequest = nil
    capturingShortcut = false
    capturesModifierSides = preferences.shortcut?.distinguishesModifierSides == true
    if let shortcut = preferences.shortcut {
      shortcutMonitor.start(definition: shortcut, activationMode: preferences.shortcutActivationMode)
    }
  }

  func setModifierSideDistinction(_ enabled: Bool) {
    guard !coordinator.canCancel else { return }
    if enabled {
      capturesModifierSides = true
      shortcutCaptureRequest = UUID()
    } else if let shortcut = preferences.shortcut {
      preferences.shortcut = shortcut.removingModifierSideDistinction()
      capturesModifierSides = false
    }
  }

  func acceptShortcut(_ definition: ShortcutDefinition) {
    let noModifiers = definition.modifiers == 0
    if noModifiers, !definition.isModifierOnly {
      shortcutConfirmation = definition
    } else {
      preferences.shortcut = definition
    }
  }

  func confirmRiskyShortcut() {
    guard let shortcutConfirmation else { return }
    preferences.shortcut = shortcutConfirmation
    self.shortcutConfirmation = nil
  }

  func validateAndSave(_ value: String, kind: CredentialKind) {
    guard !preferences.offlineMode, !changingOfflineMode else { return }
    credentialManager.beginValidation(
      value, kind: kind, configuration: credentialValidationConfiguration(for: kind))
  }

  func importLegacyCredential(_ kind: CredentialKind) {
    guard !preferences.offlineMode, !changingOfflineMode else { return }
    credentialManager.beginLegacyImport(
      kind: kind, configuration: credentialValidationConfiguration(for: kind))
  }

  func cancelCredentialValidation(_ kind: CredentialKind) {
    credentialManager.cancelValidation(kind)
  }

  func remove(_ kind: CredentialKind) {
    credentialManager.remove(kind)
  }

  func finishOnboarding(launchAtLogin: Bool) -> OnboardingFinishResult {
    Self.finishOnboarding(
      preferences: preferences, readiness: onboardingReadiness, launchAtLogin: launchAtLogin)
  }

  static func finishOnboarding(
    preferences: AppPreferences, readiness: OnboardingReadiness, launchAtLogin: Bool
  ) -> OnboardingFinishResult {
    guard readiness.isComplete else { return .incomplete }
    guard preferences.setLaunchAtLogin(launchAtLogin) else { return .loginItemFailed }
    preferences.onboardingComplete = true
    return .completed
  }

  func requestOrRefreshPermissions() async {
    await requestMicrophonePermissionIfNeeded()
    requestAccessibilityPermission()
  }

  func requestAccessibilityPermission() {
    if !AXIsProcessTrusted() {
      _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }
    permissionRefresh += 1
  }

  func requestMicrophonePermissionIfNeeded() async {
    if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
      _ = await AVCaptureDevice.requestAccess(for: .audio)
    }
    permissionRefresh += 1
  }

  func openMicrophonePrivacySettings() {
    guard
      let url = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    else { return }
    NSWorkspace.shared.open(url)
  }

  func revealBenchmarkFolder() {
    try? FileManager.default.createDirectory(
      at: benchmarkRecorder.directoryURL, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    NSWorkspace.shared.activateFileViewerSelecting([benchmarkRecorder.directoryURL])
  }

  func prewarmTranscription() {
    let usesLocal = preferences.effectiveTranscriptionProvider == .local
    localModel.select(usesLocal && preferences.localTranscriptionModel == .nemotron)
    appleSpeech.select(usesLocal && preferences.localTranscriptionModel == .apple,
                       localeIdentifier: preferences.appleSpeechLocale)
    grokPreparation.request()
    if preferences.effectiveTranscriptionProvider == .grok, !grokPreparation.isEligible { return }
    guard !preferences.offlineMode, !changingOfflineMode, !usesLocal else { return }
    let runtime = runtimeDiagnostics
    let token = runtime.beginPreparation(network: true)
    RealtimeTranscriptionPrewarmer.prewarm(provider: preferences.transcriptionProvider) {
      [weak runtime] success in
      Task { @MainActor in
        runtime?.finishPreparation(token, result: success ? .prepared : .failed)
      }
    }
  }

  private func grokConfigurationChanged() {
    grokPreparation.invalidate()
    grokPreparation.request()
  }

  func transcriptionWillSleep() { grokPreparation.setSleeping(true) }

  func transcriptionDidWake() {
    refreshTranscriptionSessionEligibility()
    grokPreparation.setSleeping(false)
    prewarmTranscription()
  }

  func transcriptionLockChanged(_ locked: Bool) { grokPreparation.setLocked(locked) }

  func stopTranscriptionPreparation() { grokPreparation.stop() }

  func refreshTranscriptionSessionEligibility() {
    // An unavailable session state fails closed; waking does not imply unlocking.
    guard let session = CGSessionCopyCurrentDictionary() as? [String: Any],
      session[kCGSessionOnConsoleKey as String] as? Bool == true else {
      grokPreparation.setLocked(true)
      return
    }
    grokPreparation.setLocked(session["CGSSessionScreenIsLocked"] as? Bool == true)
  }

  func clearCompletedBenchmarkHistory() {
    benchmarkRecorder.clearCompletedHistory()
  }

  private func credentialValidationConfiguration(
    for kind: CredentialKind
  ) -> CleanupConfiguration? {
    switch kind {
    case .soniox: nil
    case .metaModelAPI: nil
    case .xai: nil
    case .openRouter: preferences.cleanupConfiguration(for: .openRouter)
    case .groq: preferences.cleanupConfiguration(for: .groq)
    case .cerebras: preferences.cleanupConfiguration(for: .cerebras)
    }
  }
}

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
  let preferences: AppPreferences
  let coordinator: DictationCoordinator
  let credentialManager: CredentialManager
  let benchmarkRecorder: LatencyBenchmarkRecorder

  @Published var shortcutConfirmation: ShortcutDefinition?
  @Published var permissionRefresh = 0
  @Published var settingsDestinationRequest: SettingsDestination?

  private let shortcutMonitor = GlobalShortcutMonitor()
  private var cancellables = Set<AnyCancellable>()

  init() {
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
    let benchmarkRecorder = LatencyBenchmarkRecorder()
    self.preferences = preferences
    self.credentialManager = credentialManager
    self.benchmarkRecorder = benchmarkRecorder
    coordinator = DictationCoordinator(
      preferences: preferences, credentials: credentials, benchmark: benchmarkRecorder)
    credentialManager.objectWillChange.sink { [weak self] in
      self?.objectWillChange.send()
    }.store(in: &cancellables)
    shortcutMonitor.onPress = { [weak coordinator] in coordinator?.shortcutPressed() }
    shortcutMonitor.onHoldRelease = { [weak coordinator] lifecycleGeneration in
      coordinator?.finishHeldDictation(lifecycleGeneration: lifecycleGeneration)
    }
    shortcutMonitor.onCancel = { [weak coordinator] in coordinator?.cancel() }
    shortcutMonitor.shouldCancel = { [weak coordinator] in coordinator?.canCancel == true }
    preferences.$shortcut.combineLatest(preferences.$shortcutActivationMode)
      .sink { [weak self] definition, activationMode in
        guard let self else { return }
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
        self.permissionRefresh += 1
        guard AXIsProcessTrusted(), let shortcut = self.preferences.shortcut else { return }
        self.shortcutMonitor.start(
          definition: shortcut, activationMode: self.preferences.shortcutActivationMode)
      }
      .store(in: &cancellables)
  }

  var readinessComplete: Bool {
    preferences.shortcut != nil
      && hasCredential(preferences.transcriptionProvider.credentialKind)
      && hasCredential(preferences.cleanupProvider.credentialKind) && permissionsReady
  }

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
    credentialManager.beginValidation(
      value, kind: kind, configuration: credentialValidationConfiguration(for: kind))
  }

  func importLegacyCredential(_ kind: CredentialKind) {
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
    guard preferences.shortcut != nil,
      hasCredential(preferences.transcriptionProvider.credentialKind), hasCredential(.openRouter),
      permissionsReady
    else { return .incomplete }
    guard preferences.setLaunchAtLogin(launchAtLogin) else { return .loginItemFailed }
    preferences.cleanupProvider = .openRouter
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

  func clearCompletedBenchmarkHistory() {
    benchmarkRecorder.clearCompletedHistory()
  }

  private func credentialValidationConfiguration(
    for kind: CredentialKind
  ) -> CleanupConfiguration? {
    switch kind {
    case .soniox: nil
    case .metaModelAPI: nil
    case .openRouter: preferences.cleanupConfiguration(for: .openRouter)
    case .groq: preferences.cleanupConfiguration(for: .groq)
    case .cerebras: preferences.cleanupConfiguration(for: .cerebras)
    }
  }
}

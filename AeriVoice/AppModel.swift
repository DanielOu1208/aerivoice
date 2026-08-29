import AVFoundation
import AppKit
import Combine
import ServiceManagement

enum CredentialStatus: Equatable {
  case missing
  case saved
  case validating
  case error(String)
}

@MainActor
final class AppModel: ObservableObject {
  let preferences: AppPreferences
  let coordinator: DictationCoordinator
  let credentials: KeychainStore

  @Published var sonioxStatus: CredentialStatus
  @Published var openRouterStatus: CredentialStatus
  @Published var shortcutConfirmation: ShortcutDefinition?
  @Published var permissionRefresh = 0

  private let shortcutMonitor = GlobalShortcutMonitor()
  private var cancellables = Set<AnyCancellable>()

  init() {
    let preferences = AppPreferences()
    let credentials = KeychainStore()
    self.preferences = preferences
    self.credentials = credentials
    coordinator = DictationCoordinator(preferences: preferences, credentials: credentials)
    sonioxStatus = credentials.value(for: .soniox) == nil ? .missing : .saved
    openRouterStatus = credentials.value(for: .openRouter) == nil ? .missing : .saved
    shortcutMonitor.onToggle = { [weak coordinator] in coordinator?.toggle() }
    shortcutMonitor.onCancel = { [weak coordinator] in coordinator?.cancel() }
    shortcutMonitor.shouldCancel = { [weak coordinator] in coordinator?.canCancel == true }
    preferences.$shortcut.sink { [weak self] definition in
      guard let self else { return }
      if let definition {
        self.shortcutMonitor.start(definition: definition)
      } else {
        self.shortcutMonitor.stop()
      }
    }.store(in: &cancellables)
    NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
      .sink { [weak self] _ in
        guard let self, AXIsProcessTrusted(), let shortcut = self.preferences.shortcut else {
          return
        }
        self.permissionRefresh += 1
        self.shortcutMonitor.start(definition: shortcut)
      }
      .store(in: &cancellables)
  }

  var setupComplete: Bool {
    preferences.onboardingComplete && preferences.shortcut != nil && hasCredential(.soniox)
      && hasCredential(.openRouter) && permissionsReady
  }

  func hasCredential(_ kind: CredentialKind) -> Bool {
    credentials.value(for: kind).map { !$0.isEmpty } == true
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

  func validateAndSave(_ value: String, kind: CredentialKind) async {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      setStatus(.error("Enter a key first."), kind: kind)
      return
    }
    setStatus(.validating, kind: kind)
    do {
      switch kind {
      case .openRouter:
        try await OpenRouterCleanupClient().validate(apiKey: trimmed)
      case .soniox:
        let client = SonioxRealtimeClient()
        try await client.connect(apiKey: trimmed, vocabulary: [], sessionID: DictationSessionID())
        try await client.send(Data(repeating: 0, count: 3_200))
        do { _ = try await client.finish() } catch AppError.emptyTranscript {}
        client.cancel()
      }
      try credentials.save(trimmed, for: kind)
      setStatus(.saved, kind: kind)
    } catch {
      setStatus(.error(error.localizedDescription), kind: kind)
    }
  }

  func remove(_ kind: CredentialKind) {
    do {
      try credentials.remove(kind)
      setStatus(.missing, kind: kind)
    } catch {
      setStatus(.error(error.localizedDescription), kind: kind)
    }
  }

  func finishSetup() {
    guard preferences.shortcut != nil, hasCredential(.soniox), hasCredential(.openRouter),
      permissionsReady
    else { return }
    preferences.onboardingComplete = true
    if preferences.launchAtLogin, SMAppService.mainApp.status == .notRegistered {
      preferences.setLaunchAtLogin(true)
    }
  }

  func requestOrRefreshPermissions() async {
    await requestMicrophonePermissionIfNeeded()
    if !AXIsProcessTrusted() {
      _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }
    if let shortcut = preferences.shortcut { shortcutMonitor.start(definition: shortcut) }
  }

  func requestMicrophonePermissionIfNeeded() async {
    if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
      _ = await AVCaptureDevice.requestAccess(for: .audio)
    }
    permissionRefresh += 1
  }

  private func setStatus(_ status: CredentialStatus, kind: CredentialKind) {
    switch kind {
    case .soniox: sonioxStatus = status
    case .openRouter: openRouterStatus = status
    }
    objectWillChange.send()
  }
}

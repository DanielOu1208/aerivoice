import AVFoundation
import SwiftUI

enum OnboardingStep: Int, CaseIterable {
  case providers
  case permissions
  case shortcut

  var title: String {
    switch self {
    case .providers: "Connect your services"
    case .permissions: "Allow system access"
    case .shortcut: "Choose your shortcut"
    }
  }

}

struct OnboardingReadiness: Equatable, Sendable {
  let hasSonioxCredential: Bool
  let hasOpenRouterCredential: Bool
  let hasPermissions: Bool
  let hasShortcut: Bool

  var recommendedStep: OnboardingStep {
    if !hasSonioxCredential || !hasOpenRouterCredential { return .providers }
    if !hasPermissions { return .permissions }
    return .shortcut
  }

  func canAdvance(from step: OnboardingStep) -> Bool {
    switch step {
    case .providers: hasSonioxCredential && hasOpenRouterCredential
    case .permissions: hasPermissions
    case .shortcut: hasShortcut
    }
  }
}

struct OnboardingView: View {
  @ObservedObject var model: AppModel
  @ObservedObject private var preferences: AppPreferences
  let onFinished: () -> Void

  @State private var step: OnboardingStep
  @State private var launchAtLogin: Bool
  @State private var failedLoginItemRequest: Bool?

  init(model: AppModel, onFinished: @escaping () -> Void) {
    self.model = model
    self.preferences = model.preferences
    self.onFinished = onFinished
    _step = State(initialValue: Self.readiness(for: model).recommendedStep)
    _launchAtLogin = State(initialValue: model.preferences.launchAtLogin)
  }

  var body: some View {
    VStack(spacing: 0) {
      onboardingHeader
      Divider()
      stepContent
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      Divider()
      navigation
    }
    .frame(minWidth: 700, minHeight: 560)
    .alert(
      "Use this shortcut systemwide?",
      isPresented: Binding(
        get: { model.shortcutConfirmation != nil },
        set: { if !$0 { model.shortcutConfirmation = nil } })
    ) {
      Button("Cancel", role: .cancel) { model.shortcutConfirmation = nil }
      Button("Use Shortcut") { model.confirmRiskyShortcut() }
    } message: {
      Text(
        "A shortcut without modifier keys will be consumed everywhere while AeriVoice is running.")
    }
    .alert(
      failedLoginItemRequest == true
        ? "Couldn’t enable launch at login" : "Couldn’t disable launch at login",
      isPresented: Binding(
        get: { failedLoginItemRequest != nil },
        set: { if !$0 { failedLoginItemRequest = nil } })
    ) {
      Button("OK", role: .cancel) { failedLoginItemRequest = nil }
    } message: {
      if failedLoginItemRequest == true {
        Text(
          "macOS didn’t accept the login item change. Turn the option off to finish setup, or try again."
        )
      } else {
        Text(
          "macOS didn’t remove the login item. Try again before finishing setup."
        )
      }
    }
  }

  private var onboardingHeader: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Label("AeriVoice", systemImage: "waveform")
          .font(.system(size: 24, weight: .semibold))
        Spacer()
        Text("Step \(step.rawValue + 1) of \(OnboardingStep.allCases.count)")
          .foregroundStyle(.secondary)
      }
      ProgressView(
        value: Double(step.rawValue + 1), total: Double(OnboardingStep.allCases.count))
      VStack(alignment: .leading, spacing: 3) {
        Text(step.title).font(.title3.weight(.semibold))
        Text(stepSubtitle).foregroundStyle(.secondary)
      }
    }
    .padding(24)
  }

  @ViewBuilder private var stepContent: some View {
    switch step {
    case .providers:
      Form {
        Section {
          CredentialEditorView(model: model, kind: .soniox, allowsRemoval: false)
        }
        Section {
          CredentialEditorView(model: model, kind: .openRouter, allowsRemoval: false)
        }
        Section {
          Label(
            "Additional and experimental cleanup providers can be configured later in Settings.",
            systemImage: "info.circle"
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        }
      }
      .formStyle(.grouped)
    case .permissions:
      permissionStep
    case .shortcut:
      shortcutStep
    }
  }

  private var permissionStep: some View {
    let _ = model.permissionRefresh
    let microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    let microphoneAction = MicrophonePermissionAction(status: microphoneStatus)
    return Form {
      Section {
        Text(
          "AeriVoice asks only for the two permissions it needs. Neither permission gives AeriVoice access to stored recordings or passwords."
        )
        .foregroundStyle(.secondary)
      }
      Section {
        PermissionStatusRow(
          title: "Microphone",
          detail: "Captures speech only while you are actively dictating.",
          granted: microphoneStatus == .authorized,
          actionTitle: microphoneAction.title
        ) {
          if microphoneAction == .request {
            Task { await model.requestMicrophonePermissionIfNeeded() }
          } else if microphoneAction == .openSettings {
            model.openMicrophonePrivacySettings()
          }
        }
        PermissionStatusRow(
          title: "Accessibility",
          detail: "Inserts the finished text into the app you are using.",
          granted: AXIsProcessTrusted(),
          actionTitle: "Allow Accessibility"
        ) {
          model.requestAccessibilityPermission()
        }
      }
    }
    .formStyle(.grouped)
  }

  private var shortcutStep: some View {
    Form {
      Section("Activation shortcut") {
        ShortcutRecorder(current: preferences.shortcut, onCapture: model.acceptShortcut)
          .frame(maxWidth: .infinity)
        Picker("Shortcut behavior", selection: $preferences.shortcutActivationMode) {
          ForEach(ShortcutActivationMode.allCases) { mode in
            Text(mode.title).tag(mode)
          }
        }
        .pickerStyle(.segmented)
        Text(preferences.shortcutActivationMode.instructions)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Section("Startup") {
        Toggle("Launch AeriVoice at login", isOn: $launchAtLogin)
        Text("AeriVoice stays in the menu bar and waits for your shortcut.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
  }

  private var navigation: some View {
    HStack {
      if step != .providers {
        Button("Back") { move(by: -1) }
      }
      Spacer()
      if step == .shortcut {
        Button(finishButtonTitle) { finish() }
          .buttonStyle(.borderedProminent)
          .disabled(!canAdvance)
      } else {
        Button("Continue") { move(by: 1) }
          .buttonStyle(.borderedProminent)
          .disabled(!canAdvance)
      }
    }
    .padding(18)
  }

  private var stepSubtitle: String {
    switch step {
    case .providers:
      "AeriVoice uses Soniox for transcription and OpenRouter for stable AI cleanup."
    case .permissions:
      "You stay in control of when AeriVoice can listen and insert text."
    case .shortcut:
      preferences.shortcutActivationMode == .hybrid
        ? "Tap or hold one shortcut to dictate from any app."
        : "One shortcut starts and stops dictation from any app."
    }
  }

  private var canAdvance: Bool {
    Self.readiness(for: model).canAdvance(from: step)
  }

  private var finishButtonTitle: String {
    guard let shortcut = preferences.shortcut else { return "Choose a shortcut" }
    return "Start with \(shortcut.displayName)"
  }

  private func move(by offset: Int) {
    guard let next = OnboardingStep(rawValue: step.rawValue + offset) else { return }
    withAnimation(.easeInOut(duration: 0.2)) { step = next }
  }

  private func finish() {
    switch model.finishOnboarding(launchAtLogin: launchAtLogin) {
    case .completed:
      onFinished()
    case .incomplete:
      break
    case .loginItemFailed:
      failedLoginItemRequest = launchAtLogin
    }
  }

  @MainActor private static func readiness(for model: AppModel) -> OnboardingReadiness {
    OnboardingReadiness(
      hasSonioxCredential: model.hasCredential(.soniox),
      hasOpenRouterCredential: model.hasCredential(.openRouter),
      hasPermissions: model.permissionsReady,
      hasShortcut: model.preferences.shortcut != nil)
  }
}

import Speech
import SwiftUI

struct OfflineModeControl: View {
  @ObservedObject var model: AppModel
  @ObservedObject private var preferences: AppPreferences

  init(model: AppModel) {
    self.model = model
    preferences = model.preferences
  }

  var body: some View {
    Toggle(
      "Offline mode",
      isOn: Binding(
        get: { preferences.offlineMode && !model.changingOfflineMode },
        set: { model.setOfflineMode($0) })
    )
    .disabled(!model.canChangeOfflineMode)
    Text(model.offlineModeExplanation).font(.caption).foregroundStyle(.secondary)
    if !model.selectedLocalAssetsInstalled {
      Button("Set up local model…") { model.showLocalSetup() }
    }
  }
}

struct LocalTranscriptionSettings: View {
  @ObservedObject var model: AppModel
  @ObservedObject private var preferences: AppPreferences
  @State private var installedAppleLocales: Set<String> = []

  init(model: AppModel) {
    self.model = model
    preferences = model.preferences
  }

  var body: some View {
    Picker(
      "Local model",
      selection: Binding(
        get: { preferences.localTranscriptionModel }, set: { model.setLocalTranscriptionModel($0) })
    ) {
      ForEach(LocalTranscriptionModel.allCases) { choice in
        Text(choice.title).tag(choice)
          .disabled(preferences.offlineMode && !isInstalled(choice))
      }
    }
    .disabled(model.coordinator.canCancel || model.changingOfflineMode)
    Text("Accuracy may be lower than cloud models.")
      .font(.caption).foregroundStyle(.secondary)
    if preferences.localTranscriptionModel == .nemotron {
      LocalModelSetupView(
        controller: model.localModel, offline: preferences.offlineMode,
        allowsPreparation: preferences.effectiveTranscriptionProvider == .local
      )
      .disabled(model.coordinator.canCancel || model.changingOfflineMode)
    } else {
      appleSetup
    }
  }

  private func isInstalled(_ choice: LocalTranscriptionModel) -> Bool {
    choice == .apple ? model.appleSpeech.assetsInstalled : model.localModel.assetsInstalled
  }

  @ViewBuilder private var appleSetup: some View {
    Picker(
      "Language",
      selection: Binding(
        get: {
          preferences.appleSpeechLocale.isEmpty
            ? model.appleSpeech.localeIdentifier : preferences.appleSpeechLocale
        },
        set: { value in
          guard !model.coordinator.canCancel, !model.changingOfflineMode,
            !preferences.offlineMode || installedAppleLocales.contains(value)
          else { return }
          preferences.appleSpeechLocale = value
        })
    ) {
      Text("Choose a language…").tag("")
      ForEach(model.appleSpeech.supportedLocales, id: \.identifier) { locale in
        Text(Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier)
          .tag(locale.identifier)
          .disabled(preferences.offlineMode && !installedAppleLocales.contains(locale.identifier))
      }
    }
    .disabled(
      model.coordinator.canCancel || model.changingOfflineMode || model.appleSpeech.isDownloading
    )
    .task(id: model.appleSpeech.state) {
      installedAppleLocales = Set(await SpeechTranscriber.installedLocales.map(\.identifier))
      if preferences.appleSpeechLocale.isEmpty, !model.appleSpeech.localeIdentifier.isEmpty {
        preferences.appleSpeechLocale = model.appleSpeech.localeIdentifier
      }
    }
    Text(
      "Transcribes on this Mac. No NVIDIA model download required. Apple may need to download language support."
    )
    .font(.caption).foregroundStyle(.secondary)
    switch model.appleSpeech.state {
    case .ready:
      Label("Ready · works offline", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
    case .preparing:
      ProgressView("Checking Apple Speech…")
    case .missing:
      Button("Download Apple language support") { model.appleSpeech.download() }
        .disabled(preferences.offlineMode || model.changingOfflineMode)
    case .downloading(let progress):
      ProgressView("Downloading Apple language support…", value: progress)
      Text("macOS manages this download and may retry it later if it fails.")
        .font(.caption).foregroundStyle(.secondary)
    case .unavailable(let message):
      Text(message).font(.caption).foregroundStyle(.secondary)
    case .failed(let message):
      Text(message).font(.caption).foregroundStyle(.red)
      Button("Check installed language support") { model.appleSpeech.prepareIfNeeded() }
      Button("Retry download") { model.appleSpeech.download() }
        .disabled(preferences.offlineMode || model.changingOfflineMode)
    }
    if preferences.offlineMode && !model.appleSpeech.assetsInstalled {
      Text("Turn off Offline mode before downloading language support.")
        .font(.caption).foregroundStyle(.secondary)
    }
  }
}

struct ActivationShortcutRecorder: View {
  @ObservedObject var model: AppModel
  @ObservedObject private var preferences: AppPreferences

  init(model: AppModel) {
    self.model = model
    preferences = model.preferences
  }

  var body: some View {
    ShortcutRecorder(
      current: preferences.shortcut,
      distinguishModifierSides: model.capturesModifierSides,
      captureRequestID: model.shortcutCaptureRequest,
      onCaptureStart: model.beginShortcutCapture,
      onCaptureEnd: model.endShortcutCapture,
      onCapture: model.acceptShortcut
    )
    .frame(maxWidth: .infinity)
    .disabled(model.coordinator.canCancel || model.changingOfflineMode)
    Toggle(
      "Distinguish left and right keys",
      isOn: Binding(
        get: { model.capturesModifierSides }, set: { model.setModifierSideDistinction($0) })
    )
    .help(
      "Match the exact Command and Option keys. Turning this on asks you to record the shortcut again."
    )
    .disabled(model.coordinator.canCancel || model.changingOfflineMode)
  }
}

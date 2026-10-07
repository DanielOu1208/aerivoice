import SwiftUI

enum TranscriptionChoice: String, CaseIterable, Identifiable {
  case soniox, meta, grok, cartesiaInk2, cartesiaInkPreview, nemotron, apple

  var id: Self { self }
  var localModel: LocalTranscriptionModel? {
    switch self {
    case .soniox, .meta, .grok, .cartesiaInk2, .cartesiaInkPreview: nil
    case .nemotron: .nemotron
    case .apple: .apple
    }
  }
  var cartesiaModel: CartesiaTranscriptionModel? {
    switch self {
    case .cartesiaInk2: .ink2
    case .cartesiaInkPreview: .inkPreview
    case .soniox, .meta, .grok, .nemotron, .apple: nil
    }
  }
  var provider: TranscriptionProvider {
    switch self {
    case .soniox: .soniox
    case .meta: .meta
    case .grok: .grok
    case .cartesiaInk2, .cartesiaInkPreview: .cartesia
    case .nemotron, .apple: .local
    }
  }
  var title: String {
    if let cartesiaModel { return "\(provider.displayName) \(cartesiaModel.displayName)" }
    if let localModel { return localModel.title }
    // The default cloud provider is marked the way the default local model is.
    return self == .soniox ? "\(provider.displayName) — Recommended" : provider.displayName
  }

  init(
    provider: TranscriptionProvider, localModel: LocalTranscriptionModel,
    cartesiaModel: CartesiaTranscriptionModel = .ink2
  ) {
    switch provider {
    case .soniox: self = .soniox
    case .meta: self = .meta
    case .grok: self = .grok
    case .cartesia: self = cartesiaModel == .inkPreview ? .cartesiaInkPreview : .cartesiaInk2
    case .local: self = localModel == .apple ? .apple : .nemotron
    }
  }
}

struct TranscriptionModelPicker: View {
  @ObservedObject var model: AppModel
  @ObservedObject private var preferences: AppPreferences

  init(model: AppModel) {
    self.model = model
    preferences = model.preferences
  }

  private var busy: Bool {
    model.coordinator.canCancel || model.changingOfflineMode || model.appleSpeech.isDownloading
  }

  var body: some View {
    Picker("Model", selection: Binding(
      get: {
        TranscriptionChoice(provider: preferences.effectiveTranscriptionProvider,
                                      localModel: preferences.localTranscriptionModel,
                                      cartesiaModel: preferences.cartesiaTranscriptionModel)
      }, set: { model.selectTranscriptionChoice($0) }
    )) {
      Section("Cloud") {
        choices(TranscriptionChoice.allCases.filter { $0.localModel == nil })
      }
      Section("On this Mac") {
        choices(TranscriptionChoice.allCases.filter { $0.localModel != nil })
      }
    }
    .disabled(busy)
    .help("Choosing a cloud model turns off Offline mode and lets you connect your account.")
  }

  @ViewBuilder private func choices(_ choices: [TranscriptionChoice]) -> some View {
    ForEach(choices) { choice in
      Group {
        if let kind = choice.provider.credentialKind {
          ProviderMenuLabel(title: choice.title, kind: kind)
        } else {
          Label(choice.title, systemImage: choice == .apple ? "apple.logo" : "desktopcomputer")
        }
      }
      .tag(choice)
      .disabled(preferences.offlineMode && choice.localModel != nil && !isInstalled(choice))
    }
  }

  private func isInstalled(_ choice: TranscriptionChoice) -> Bool {
    choice.localModel == .apple ? model.appleSpeech.assetsInstalled : model.localModel.assetsInstalled
  }

}

/// One language for every cloud provider; the menu lists what the selected one accepts.
struct SpokenLanguagePicker: View {
  @ObservedObject var model: AppModel
  @ObservedObject private var preferences: AppPreferences

  init(model: AppModel) {
    self.model = model
    preferences = model.preferences
  }

  var body: some View {
    let configuration = preferences.transcriptionConfiguration
    let choices = TranscriptionLanguage.choices(for: configuration.provider)
    Picker("Spoken language", selection: Binding(
      get: { configuration.language ?? "" },
      set: { preferences.transcriptionLanguage = $0 }
    )) {
      Text("Auto-detect").tag("")
      ForEach(choices, id: \.self) { code in
        Text(TranscriptionLanguage.displayName(for: code)).tag(code)
      }
    }
    .disabled(choices.isEmpty || model.coordinator.canCancel || model.changingOfflineMode)
    if let note = TranscriptionLanguage.note(
      for: configuration, saved: preferences.transcriptionLanguage)
    {
      Text(note).font(.caption).foregroundStyle(.secondary)
    }
  }
}

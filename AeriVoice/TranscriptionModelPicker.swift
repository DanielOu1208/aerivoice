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
    return localModel?.title ?? provider.displayName
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
        choices([.soniox, .meta, .grok, .cartesiaInk2, .cartesiaInkPreview])
      }
      Section("On this Mac") {
        choices([.nemotron, .apple])
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

import SwiftUI

enum TranscriptionChoice: String, CaseIterable, Identifiable {
  case soniox, meta, nemotron, apple

  var id: Self { self }
  var localModel: LocalTranscriptionModel? {
    switch self {
    case .soniox, .meta: nil
    case .nemotron: .nemotron
    case .apple: .apple
    }
  }
  var provider: TranscriptionProvider {
    switch self {
    case .soniox: .soniox
    case .meta: .meta
    case .nemotron, .apple: .local
    }
  }
  var title: String { localModel?.title ?? provider.displayName }

  init(provider: TranscriptionProvider, localModel: LocalTranscriptionModel) {
    switch provider {
    case .soniox: self = .soniox
    case .meta: self = .meta
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
                                      localModel: preferences.localTranscriptionModel)
      }, set: { model.selectTranscriptionChoice($0) }
    )) {
      Section("Cloud") {
        choices([.soniox, .meta])
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
      Text(choice.title).tag(choice)
        .disabled(preferences.offlineMode && choice.localModel != nil && !isInstalled(choice))
    }
  }

  private func isInstalled(_ choice: TranscriptionChoice) -> Bool {
    choice.localModel == .apple ? model.appleSpeech.assetsInstalled : model.localModel.assetsInstalled
  }

}

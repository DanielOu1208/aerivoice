import SwiftUI

struct OnboardingProviderSetup: View {
  @ObservedObject var model: AppModel
  @ObservedObject private var preferences: AppPreferences

  init(model: AppModel) {
    self.model = model
    preferences = model.preferences
  }

  private var usesLocal: Bool { preferences.effectiveTranscriptionProvider == .local }
  private var busy: Bool {
    model.coordinator.canCancel || model.changingOfflineMode || model.appleSpeech.isDownloading
  }

  var body: some View {
    Form {
      if !usesLocal {
        Section("On this Mac") {
          HStack(spacing: 12) {
            Image(systemName: "desktopcomputer").font(.title2).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
              Text("Local models").font(.headline)
              Text("Apple Speech or NVIDIA Nemotron. No transcription account required.")
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Use local models") { model.selectTranscriptionChoice(.apple) }
              .disabled(busy)
          }
        }
      }
      Section {
        if usesLocal {
          HStack {
            TranscriptionModelPicker(model: model)
            SettingsInfoButton(title: "Local transcription", message: preferences.localTranscriptionModel.setupDescription)
          }
          LocalTranscriptionSettings(model: model, presentation: .onboarding)
          OfflineModeControl(model: model, offersLocalSetup: false)
        } else {
          ProviderSelectionRow(
            model: model, kind: preferences.effectiveTranscriptionProvider.credentialKind,
            allowsRemoval: false, allowsLocalManagement: false, showsProviderIcon: false
          ) {
            TranscriptionModelPicker(model: model)
          }
          .id(preferences.effectiveTranscriptionProvider)
          .disabled(busy)
        }
      } header: {
        Text("Transcription")
      } footer: {
        if usesLocal {
          Text("Local accuracy may be lower than cloud models.")
        }
      }
      if !preferences.offlineMode {
        Section("AI cleanup") {
          ProviderSelectionRow(
            model: model, kind: preferences.cleanupProvider.credentialKind, allowsRemoval: false
          ) {
            Picker("Provider", selection: $preferences.cleanupProvider) {
              ForEach(CleanupProvider.allCases, id: \.self) { provider in
                Text(provider.displayName + (provider.isExperimental ? " (Experimental)" : ""))
                  .tag(provider)
              }
            }
          }
          .id(preferences.cleanupProvider)
          .disabled(model.changingOfflineMode || model.coordinator.canCancel)
        }
      }
    }
    .formStyle(.grouped)
  }

}

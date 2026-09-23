import AVFoundation
import AppKit
import SwiftUI

struct GeneralSettingsPage: View {
  @ObservedObject var model: AppModel
  @ObservedObject private var preferences: AppPreferences

  init(model: AppModel) {
    self.model = model
    self.preferences = model.preferences
  }

  var body: some View {
    Form {
      Section("Offline") { OfflineModeControl(model: model) }
      Section("Activation shortcut") {
        ActivationShortcutRecorder(model: model)
        SettingsControlRow(
          title: "Shortcut behavior", message: preferences.shortcutActivationMode.instructions
        ) {
          Picker("Shortcut behavior", selection: $preferences.shortcutActivationMode) {
            ForEach(ShortcutActivationMode.allCases) { mode in Text(mode.title).tag(mode) }
          }
          .pickerStyle(.menu)
        }
      }
      Section("Recording feedback") {
        Toggle("Mute audio while recording", isOn: $preferences.muteOutput)
        Toggle("Play recording sounds", isOn: $preferences.soundCues)
          .help("Play a sound when recording starts, stops, or encounters an error.")
      }
      Section("Clipboard") {
        SettingsControlRow(
          title: "Restore clipboard after dictation",
          message:
            "Restores your previous clipboard after insertion is confirmed. Otherwise, dictation stays copied."
        ) {
          Toggle("Restore clipboard after dictation", isOn: $preferences.restoreClipboard)
        }
      }
      Section("Startup") {
        Toggle(
          "Launch AeriVoice at login",
          isOn: Binding(
            get: { preferences.launchAtLogin },
            set: { preferences.setLaunchAtLogin($0) }))
      }
    }
    .formStyle(.grouped)
    .contentMargins(.top, -8, for: .scrollContent)
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
  }
}

struct DictationSettingsPage: View {
  @ObservedObject var model: AppModel
  @ObservedObject private var preferences: AppPreferences
  @Binding var selection: SettingsDestination

  init(model: AppModel, selection: Binding<SettingsDestination>) {
    self.model = model
    self.preferences = model.preferences
    _selection = selection
  }

  var body: some View {
    Form {
      Section("Transcription") {
        ProviderSelectionRow(
          model: model, kind: preferences.effectiveTranscriptionProvider.credentialKind,
          showsProviderIcon: false
        ) {
          TranscriptionModelPicker(model: model)
        }
        .id(preferences.effectiveTranscriptionProvider)
        .disabled(model.coordinator.canCancel || model.changingOfflineMode)
        if preferences.effectiveTranscriptionProvider != .local {
          LabeledContent {
            Text(preferences.transcriptionProvider.modelDisplayName).foregroundStyle(.secondary)
          } label: {
            if preferences.transcriptionProvider == .meta {
              SettingsHelpLabel(
                title: "Model",
                message:
                  "Meta streams use Muse Voice Transcribe and request Zero Data Retention for every session."
              )
            } else {
              Text("Model")
            }
          }
        }
      }
      if preferences.offlineMode {
        Text("Offline mode uses local transcription. AI cleanup is off.")
          .font(.caption).foregroundStyle(.secondary)
      }
      Section {
        VocabularyTagEditor(vocabulary: $preferences.vocabulary)
        if preferences.effectiveTranscriptionProvider == .grok {
          Text("Grok uses up to 100 dictionary terms, each up to 50 characters. Spelling is not guaranteed.")
            .font(.caption).foregroundStyle(.secondary)
          let excluded = GrokVocabulary(VocabularyNormalizer.normalize(preferences.vocabulary)).excluded
          if !excluded.isEmpty {
            Text("Not sent to Grok (\(excluded.count)): " + excluded.joined(separator: ", "))
              .font(.caption).foregroundStyle(.orange)
          }
        }
      } header: {
        SettingsHelpLabel(
          title: "Dictionary",
          message: preferences.effectiveTranscriptionProvider == .local
            ? "Local uses these words as recognition hints from the next recording; spelling is not guaranteed."
            : "Names and phrases are sent to your selected transcription provider as hints.")
      }
      Section("Microphone") {
        HStack {
          Label(
            AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
              ? "Microphone access allowed" : "Microphone access required",
            systemImage: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
              ? "checkmark.circle.fill" : "exclamationmark.circle.fill"
          )
          .foregroundStyle(
            AVCaptureDevice.authorizationStatus(for: .audio) == .authorized ? .green : .orange)
          Spacer()
          Button("Manage…") { selection = .privacy }
        }
      }
    }
    .formStyle(.grouped)
    .contentMargins(.top, -8, for: .scrollContent)
  }
}

struct CleanupSettingsPage: View {
  @ObservedObject var model: AppModel
  @ObservedObject private var preferences: AppPreferences
  @ObservedObject private var catalog: OpenRouterCatalogStore
  @State private var showsModelPicker = false

  init(model: AppModel) {
    self.model = model
    self.preferences = model.preferences
    self.catalog = model.preferences.openRouterCatalog
  }

  var body: some View {
    Form {
      Section("Cleanup style") {
        SettingsControlRow(title: "Style", message: preferences.cleanupMode.summary) {
          CleanupStylePicker(selection: $preferences.cleanupMode)
        }
        if preferences.cleanupMode == .compose {
          ExperimentalCleanupNotice()
        }
        if preferences.cleanupMode == .custom {
          CleanupInstructionsEditor(preferences: preferences)
        }
      }
      Section("Provider") {
        ProviderSelectionRow(
          model: model, kind: preferences.cleanupProvider.credentialKind, showsProviderIcon: false
        ) {
          Picker("Provider", selection: $preferences.cleanupProvider) {
            ForEach(CleanupProvider.allCases, id: \.self) { provider in
              ProviderMenuLabel(
                title: provider.isExperimental
                  ? "\(provider.displayName) — Experimental" : provider.displayName,
                kind: provider.credentialKind
              )
              .tag(provider)
            }
          }
        }
        .id(preferences.cleanupProvider)

        if preferences.cleanupProvider == .openRouter {
          LabeledContent("Model") {
            Button {
              showsModelPicker = true
            } label: {
              HStack(spacing: 6) {
                Text(selectedModelName)
                  .lineLimit(1).truncationMode(.middle)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold))
              }
              .foregroundStyle(.secondary)
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(preferences.cleanupModel.rawValue)
            .accessibilityLabel("Choose cleanup model, \(selectedModelName)")
          }
        } else {
          Picker(
            "Model",
            selection: Binding(
              get: { preferences.cleanupModel },
              set: { preferences.cleanupModel = $0 })
          ) {
            ForEach(preferences.cleanupProvider.models, id: \.self) { cleanupModel in
              Text(cleanupModel.displayName).tag(cleanupModel)
            }
          }
          .pickerStyle(.menu)
        }

        CleanupReasoningPicker(preferences: preferences)
        if preferences.cleanupModel.isOpenRouterCatalogModel {
          SettingsControlRow(
            title: "Require zero data retention",
            message:
              "Only providers that support zero data retention can serve this model when enabled."
          ) {
            Toggle(
              "Require zero data retention", isOn: $preferences.catalogRequiresZeroDataRetention)
          }
          if !preferences.catalogRequiresZeroDataRetention {
            warning("The selected provider may retain your transcript and cleaned text.")
          }
        }
        if preferences.cleanupProvider == .groq {
          warning(
            "Groq is experimental and may retain transcripts. Manage retention in Groq Data Controls."
          )
        } else if preferences.cleanupModel == .gpt56LunaFast {
          warning(
            "Luna Fast may retain prompts. Choose another model if zero data retention is required."
          )
        }
      }
    }
    .disabled(preferences.offlineMode || model.changingOfflineMode)
    .safeAreaInset(edge: .top) {
      if preferences.offlineMode {
        Text("Offline mode uses local transcription. AI cleanup is off.")
          .font(.caption).foregroundStyle(.secondary).padding(.vertical, 8)
      }
    }
    .formStyle(.grouped)
    .contentMargins(.top, -8, for: .scrollContent)
    .sheet(isPresented: $showsModelPicker) {
      CleanupModelPicker(preferences: preferences)
    }
    .onReceive(model.settingsWindowWillClose) { showsModelPicker = false }
    .task(id: preferences.cleanupProvider) {
      if preferences.cleanupProvider == .openRouter {
        await catalog.refresh()
      }
    }
  }

  private var selectedModelName: String {
    catalog.entry(for: preferences.cleanupModel)?.name ?? preferences.cleanupModel.displayName
  }

  private func warning(_ text: String) -> some View {
    Label(text, systemImage: "exclamationmark.triangle.fill")
      .font(.caption).foregroundStyle(.orange)
  }
}

struct ProviderSettingsPage: View {
  @ObservedObject var model: AppModel

  var body: some View {
    Form {
      Section("Transcription") {
        Group {
          ProviderAccountRow(model: model, kind: .soniox)
          ProviderAccountRow(model: model, kind: .metaModelAPI)
          ProviderAccountRow(model: model, kind: .xai)
        }
        .disabled(model.preferences.offlineMode || model.changingOfflineMode)
        LocalProviderAccountRow(model: model)
      }
      Section("AI Cleanup") {
        ProviderAccountRow(model: model, kind: .openRouter)
        ProviderAccountRow(model: model, kind: .cerebras)
        ProviderAccountRow(model: model, kind: .groq)
      }
      .disabled(model.preferences.offlineMode || model.changingOfflineMode)
    }
    .formStyle(.grouped)
    .contentMargins(.top, -8, for: .scrollContent)
  }
}

struct PrivacySettingsPage: View {
  @ObservedObject var model: AppModel
  @ObservedObject private var preferences: AppPreferences
  @ObservedObject private var usageStats: UsageStatsModel
  @State private var confirmsBenchmarkClear = false
  @State private var confirmsStatsClear = false

  init(model: AppModel) {
    self.model = model
    self.preferences = model.preferences
    self.usageStats = model.usageStats
  }

  var body: some View {
    let _ = model.permissionRefresh
    let microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    let microphoneAction = MicrophonePermissionAction(status: microphoneStatus)
    Form {
      Section("System permissions") {
        PermissionStatusRow(
          title: "Microphone",
          detail: "Required to capture speech for transcription.",
          granted: microphoneStatus == .authorized,
          actionTitle: microphoneAction == .request ? "Request Access" : microphoneAction.title
        ) {
          if microphoneAction == .request {
            Task { await model.requestMicrophonePermissionIfNeeded() }
          } else if microphoneAction == .openSettings {
            model.openMicrophonePrivacySettings()
          }
        }
        PermissionStatusRow(
          title: "Accessibility",
          detail: "Required to insert completed text into the active app.",
          granted: AXIsProcessTrusted(), actionTitle: "Request Access"
        ) {
          model.requestAccessibilityPermission()
        }
        Button("Open Privacy & Security…") { openPrivacySettings() }
      }
      Section {
        Toggle("Collect usage stats", isOn: Binding(
          get: { usageStats.enabled },
          set: { usageStats.setEnabled($0) }
        ))
        Button("Clear Stats…", role: .destructive) { confirmsStatsClear = true }
        if let error = usageStats.storageError {
          Label(error, systemImage: "exclamationmark.triangle")
            .foregroundStyle(.orange)
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
        }
      } header: {
        Text("Usage stats")
      } footer: {
        Text("Only aggregate counts and timings are stored on this Mac. No audio or transcript text is saved.")
      }
      Section("Performance diagnostics") {
        SettingsControlRow(
          title: "Log performance measurements",
          message:
            "AeriVoice stores timings, resource use, build and device context, workload sizes, provider routing, and outcomes for up to 365 days, within a 200 MB limit. Transcript text, vocabulary, credentials, clipboard contents, and raw errors are never written."
        ) {
          Toggle("Log performance measurements", isOn: $preferences.latencyLogging)
        }
        HStack {
          Button("Reveal Data Folder") { model.revealBenchmarkFolder() }
          Spacer()
          Button("Clear History…", role: .destructive) { confirmsBenchmarkClear = true }
        }
      }
    }
    .formStyle(.grouped)
    .contentMargins(.top, -8, for: .scrollContent)
    .alert("Clear usage stats?", isPresented: $confirmsStatsClear) {
      Button("Cancel", role: .cancel) {}
      Button("Clear Stats", role: .destructive) { usageStats.clear() }
    } message: {
      Text("This permanently removes usage totals stored on this Mac. Your collection setting stays the same.")
    }
    .alert("Clear completed performance history?", isPresented: $confirmsBenchmarkClear) {
      Button("Cancel", role: .cancel) {}
      Button("Clear History", role: .destructive) { model.clearCompletedBenchmarkHistory() }
    } message: {
      Text(
        "This removes completed interaction and runtime records, including archives. A dictation currently in progress is kept."
      )
    }
  }

  private func openPrivacySettings() {
    NSWorkspace.shared.open(
      URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy")!)
  }
}

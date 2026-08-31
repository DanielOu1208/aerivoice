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
    VStack(spacing: 0) {
      SettingsPageHeader(
        title: "General",
        subtitle: "Choose how AeriVoice starts, listens, and gives feedback.")
      Divider()
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

        Section("Recording feedback") {
          Toggle("Mute audio output while recording", isOn: $preferences.muteOutput)
          Toggle("Play start, stop, and error cues", isOn: $preferences.soundCues)
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
    }
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
    VStack(spacing: 0) {
      SettingsPageHeader(
        title: "Dictation",
        subtitle: "Configure realtime transcription and words that need special recognition.")
      Divider()
      Form {
        Section("Transcription") {
          HStack {
            Label("Soniox realtime transcription", systemImage: "waveform")
            Spacer()
            connectionStatus(for: .soniox)
            Button("Manage…") { selection = .providers }
          }
        }

        Section("Dictionary") {
          VocabularyTagEditor(vocabulary: $preferences.vocabulary)
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
            Button("Manage Permissions…") { selection = .privacy }
          }
        }
      }
      .formStyle(.grouped)
    }
  }

  @ViewBuilder private func connectionStatus(for kind: CredentialKind) -> some View {
    if model.hasCredential(kind) {
      Label("Verified", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
    } else {
      Label("Not connected", systemImage: "exclamationmark.circle.fill").foregroundStyle(.orange)
    }
  }
}

struct CleanupSettingsPage: View {
  @ObservedObject var model: AppModel
  @ObservedObject private var preferences: AppPreferences
  @Binding var selection: SettingsDestination
  @State private var showsAdvanced = false

  init(model: AppModel, selection: Binding<SettingsDestination>) {
    self.model = model
    self.preferences = model.preferences
    _selection = selection
  }

  var body: some View {
    VStack(spacing: 0) {
      SettingsPageHeader(
        title: "AI Cleanup",
        subtitle: "Control how AeriVoice turns a raw transcript into finished text.")
      Divider()
      Form {
        Section("Cleanup style") {
          Picker("Style", selection: $preferences.cleanupMode) {
            ForEach(CleanupMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
          }
          .pickerStyle(.segmented)
          Text(cleanupModeDescription)
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        Section("Provider") {
          Picker("Provider", selection: $preferences.cleanupProvider) {
            ForEach(CleanupProvider.allCases, id: \.self) { provider in
              Text(
                provider.isExperimental
                  ? "\(provider.displayName) — Experimental" : provider.displayName
              )
              .tag(provider)
            }
          }
          .pickerStyle(.menu)

          HStack {
            Text("Connection")
            Spacer()
            if preferences.cleanupProvider.isExperimental { ExperimentalBadge() }
            providerConnectionStatus
            Button("Manage…") { selection = .providers }
          }

          if preferences.cleanupProvider == .groq {
            warning(
              "Direct Groq cleanup is experimental. Models and usage limits may change, and very long dictations can exceed your plan limits."
            )
            warning(
              "Groq may temporarily log inputs and outputs for reliability or abuse monitoring. Enable Zero Data Retention in Groq Data Controls to opt out."
            )
          } else if preferences.cleanupModel == .gpt56LunaFast {
            warning(
              "Luna Fast may retain prompts at the provider. Choose another model when zero data retention is required."
            )
          }
        }

        Section {
          DisclosureGroup(isExpanded: $showsAdvanced) {
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

            Picker(
              "Reasoning",
              selection: Binding(
                get: { preferences.cleanupReasoningEffort },
                set: { preferences.cleanupReasoningEffort = $0 })
            ) {
              ForEach(preferences.cleanupModel.supportedReasoningEfforts, id: \.self) { effort in
                Text(effort.displayName).tag(effort)
              }
            }
            .pickerStyle(.menu)
          } label: {
            VStack(alignment: .leading, spacing: 2) {
              Text("Advanced")
              Text(
                "\(preferences.cleanupModel.displayName) · \(preferences.cleanupReasoningEffort.displayName) reasoning"
              )
              .font(.caption)
              .foregroundStyle(.secondary)
            }
          }
        }
      }
      .formStyle(.grouped)
    }
  }

  private var cleanupModeDescription: String {
    switch preferences.cleanupMode {
    case .faithful:
      "Corrects punctuation, casing, and obvious transcription mistakes while preserving your wording."
    case .polished:
      "Allows careful rephrasing to produce smoother, more concise text."
    }
  }

  @ViewBuilder private var providerConnectionStatus: some View {
    if model.hasCredential(preferences.cleanupProvider.credentialKind) {
      Label("Verified", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
    } else {
      Label("Key required", systemImage: "exclamationmark.circle.fill").foregroundStyle(.orange)
    }
  }

  private func warning(_ text: String) -> some View {
    Label(text, systemImage: "exclamationmark.triangle.fill")
      .font(.caption)
      .foregroundStyle(.orange)
  }
}

struct ProviderSettingsPage: View {
  @ObservedObject var model: AppModel

  var body: some View {
    VStack(spacing: 0) {
      SettingsPageHeader(
        title: "Providers",
        subtitle: "Connect transcription and cleanup services. Keys stay in your Mac’s Keychain.")
      Divider()
      Form {
        Section {
          CredentialEditorView(model: model, kind: .soniox)
        }
        Section {
          CredentialEditorView(model: model, kind: .openRouter)
        }
        Section {
          CredentialEditorView(model: model, kind: .groq)
        }
      }
      .formStyle(.grouped)
    }
  }
}

struct PrivacySettingsPage: View {
  @ObservedObject var model: AppModel
  @ObservedObject private var preferences: AppPreferences
  @State private var confirmsBenchmarkClear = false

  init(model: AppModel) {
    self.model = model
    self.preferences = model.preferences
  }

  var body: some View {
    let _ = model.permissionRefresh
    let microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    let microphoneAction = MicrophonePermissionAction(status: microphoneStatus)
    VStack(spacing: 0) {
      SettingsPageHeader(
        title: "Privacy & Data",
        subtitle: "Manage system access and the diagnostic data stored on this Mac.")
      Divider()
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
            granted: AXIsProcessTrusted(),
            actionTitle: "Request Access"
          ) {
            model.requestAccessibilityPermission()
          }
          Button("Open Privacy & Security…") { openPrivacySettings() }
        }

        Section("Latency diagnostics") {
          Toggle("Log privacy-safe latency measurements", isOn: $preferences.latencyLogging)
          Text(
            "AeriVoice stores timings, workload sizes, provider routing, and outcomes for 90 days. Transcript text, vocabulary, credentials, clipboard contents, and raw errors are never written."
          )
          .font(.caption)
          .foregroundStyle(.secondary)
          HStack {
            Button("Reveal Data Folder") { model.revealBenchmarkFolder() }
            Button("Clear Completed History…", role: .destructive) {
              confirmsBenchmarkClear = true
            }
            Spacer()
          }
        }
      }
      .formStyle(.grouped)
    }
    .alert("Clear completed latency history?", isPresented: $confirmsBenchmarkClear) {
      Button("Cancel", role: .cancel) {}
      Button("Clear History", role: .destructive) {
        model.clearCompletedBenchmarkHistory()
      }
    } message: {
      Text("This removes completed benchmark records. A dictation currently in progress is kept.")
    }
  }

  private func openPrivacySettings() {
    NSWorkspace.shared.open(
      URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy")!)
  }
}

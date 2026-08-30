import AVFoundation
import AppKit
import SwiftUI

struct SettingsView: View {
  @ObservedObject var model: AppModel
  @ObservedObject private var preferences: AppPreferences
  @State private var sonioxKey = ""
  @State private var openRouterKey = ""
  @State private var removeKind: CredentialKind?
  @State private var confirmsBenchmarkClear = false

  init(model: AppModel) {
    self.model = model
    self.preferences = model.preferences
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 22) {
        header
        if !model.setupComplete { setupBanner }
        credentialSection
        shortcutSection
        behaviorSection
        latencySection
        vocabularySection
        permissionSection
        if !model.setupComplete {
          Button("Finish setup") { model.finishSetup() }
            .buttonStyle(.borderedProminent)
            .disabled(
              model.preferences.shortcut == nil || !model.hasCredential(.soniox)
                || !model.hasCredential(.openRouter) || !model.permissionsReady)
        }
      }
      .padding(24)
    }
    .frame(width: 540, height: 650)
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
      "Remove credential?",
      isPresented: Binding(get: { removeKind != nil }, set: { if !$0 { removeKind = nil } })
    ) {
      Button("Cancel", role: .cancel) { removeKind = nil }
      Button("Remove", role: .destructive) {
        if let kind = removeKind { model.remove(kind) }
        removeKind = nil
      }
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

  private var header: some View {
    VStack(alignment: .leading, spacing: 5) {
      Text("AeriVoice").font(.system(size: 26, weight: .bold))
      Text("Fast, private-by-default dictation with live Soniox transcription and Gemini cleanup.")
        .foregroundStyle(.secondary)
    }
  }

  private var setupBanner: some View {
    Label("Complete each item below before your first dictation.", systemImage: "checklist")
      .padding(12).frame(maxWidth: .infinity, alignment: .leading)
      .background(.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
  }

  private var credentialSection: some View {
    GroupBox("API credentials") {
      VStack(spacing: 14) {
        credentialRow(kind: .soniox, value: $sonioxKey, status: model.sonioxStatus)
        Divider()
        credentialRow(kind: .openRouter, value: $openRouterKey, status: model.openRouterStatus)
      }.padding(8)
    }
  }

  private func credentialRow(kind: CredentialKind, value: Binding<String>, status: CredentialStatus)
    -> some View
  {
    let hasSavedKey = model.hasCredential(kind)
    return VStack(alignment: .leading, spacing: 7) {
      HStack {
        Text(kind.label).fontWeight(.semibold)
        Spacer()
        statusView(status, hasSavedKey: hasSavedKey)
      }
      HStack {
        SecureField(hasSavedKey ? "Enter a replacement key" : "API key", text: value)
        Button(hasSavedKey ? "Replace" : "Verify & Save") {
          let candidate = value.wrappedValue
          Task {
            await model.validateAndSave(candidate, kind: kind)
            if (kind == .soniox ? model.sonioxStatus : model.openRouterStatus) == .saved {
              value.wrappedValue = ""
            }
          }
        }.disabled(value.wrappedValue.isEmpty || status == .validating)
        if hasSavedKey { Button("Remove", role: .destructive) { removeKind = kind } }
      }
      if case .error(let message) = status {
        Text(hasSavedKey ? "\(message) Existing verified key kept." : message)
          .font(.caption).foregroundStyle(.red)
      }
    }
  }

  @ViewBuilder private func statusView(_ status: CredentialStatus, hasSavedKey: Bool) -> some View {
    switch status {
    case .missing: Label("Missing", systemImage: "circle").foregroundStyle(.secondary)
    case .saved: Label("Verified", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
    case .validating:
      ProgressView().controlSize(.small)
      Text("Checking…").foregroundStyle(.secondary)
    case .error:
      Label(hasSavedKey ? "Replacement failed" : "Not saved", systemImage: "xmark.circle.fill")
        .foregroundStyle(.red)
    }
  }

  private var shortcutSection: some View {
    GroupBox("Activation shortcut") {
      ShortcutRecorder(current: preferences.shortcut, onCapture: model.acceptShortcut)
        .frame(maxWidth: .infinity).padding(8)
    }
  }

  private var behaviorSection: some View {
    GroupBox("Behavior") {
      VStack(alignment: .leading, spacing: 10) {
        Picker("Cleanup", selection: $preferences.cleanupMode) {
          ForEach(CleanupMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }.pickerStyle(.segmented)
        Toggle("Mute audio output while recording", isOn: $preferences.muteOutput)
        Toggle("Play start, stop, and error cues", isOn: $preferences.soundCues)
        Toggle(
          "Launch at login",
          isOn: Binding(
            get: { preferences.launchAtLogin }, set: { preferences.setLaunchAtLogin($0) }))
      }.padding(8)
    }
  }

  private var latencySection: some View {
    GroupBox("Latency diagnostics") {
      VStack(alignment: .leading, spacing: 10) {
        Toggle("Log privacy-safe latency measurements", isOn: $preferences.latencyLogging)
        Text(
          "Stores timings, workload sizes, provider routing, and outcomes for 90 days. Transcript text, vocabulary, credentials, clipboard contents, and raw errors are never written."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        HStack {
          Button("Reveal Benchmark Folder") { model.revealBenchmarkFolder() }
          Button("Clear Completed History", role: .destructive) {
            confirmsBenchmarkClear = true
          }
          Spacer()
        }
      }.padding(8)
    }
  }

  private var vocabularySection: some View {
    GroupBox("Soniox vocabulary") {
      VStack(alignment: .leading, spacing: 6) {
        TextEditor(text: $preferences.vocabulary).font(.system(.body, design: .monospaced)).frame(
          height: 90)
        Text(
          "One name or term per line. Duplicates are removed; the total is capped at 10,000 characters."
        ).font(.caption).foregroundStyle(.secondary)
      }.padding(8)
    }
  }

  private var permissionSection: some View {
    GroupBox("Permissions") {
      HStack {
        let _ = model.permissionRefresh
        permissionBadge(
          "Microphone", granted: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized)
        permissionBadge("Accessibility", granted: AXIsProcessTrusted())
        Spacer()
        Button("Request / Refresh") { Task { await model.requestOrRefreshPermissions() } }
        Button("Open System Settings") {
          NSWorkspace.shared.open(
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy")!)
        }
      }.padding(8)
    }
  }

  private func permissionBadge(_ name: String, granted: Bool) -> some View {
    Label(name, systemImage: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
      .foregroundStyle(granted ? .green : .orange)
  }
}

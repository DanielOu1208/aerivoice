import SwiftUI

struct SettingsPageHeader: View {
  let title: String
  let subtitle: String

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title).font(.system(size: 24, weight: .semibold))
      Text(subtitle).foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 22)
    .padding(.top, 20)
    .padding(.bottom, 14)
  }
}

struct ExperimentalBadge: View {
  var body: some View {
    Text("Experimental")
      .font(.caption2.weight(.semibold))
      .foregroundStyle(.orange)
      .padding(.horizontal, 7)
      .padding(.vertical, 3)
      .background(.orange.opacity(0.12), in: Capsule())
      .accessibilityLabel("Experimental provider")
  }
}

struct CredentialEditorView: View {
  @ObservedObject var model: AppModel
  let kind: CredentialKind
  var allowsRemoval = true

  @State private var candidate = ""
  @State private var isReplacing = false
  @State private var confirmsRemoval = false
  @State private var showsErrorDetails = false

  private var status: CredentialStatus { model.credentialStatus(for: kind) }
  private var hasSavedKey: Bool { model.hasCredential(kind) }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 8) {
        Text(kind.label).font(.headline)
        if kind == .groq { ExperimentalBadge() }
        Spacer()
        credentialStatus
      }

      Text(description).font(.callout).foregroundStyle(.secondary)

      if hasSavedKey && !isReplacing {
        HStack {
          Button("Replace Key…") { isReplacing = true }
          if allowsRemoval {
            Button("Remove", role: .destructive) { confirmsRemoval = true }
          }
          Spacer()
        }
      } else {
        HStack {
          SecureField(hasSavedKey ? "Enter a replacement key" : "API key", text: $candidate)
            .textContentType(.password)
          Button(hasSavedKey ? "Verify & Replace" : "Verify & Save") { verifyAndSave() }
            .disabled(
              candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || status == .validating)
          if hasSavedKey {
            Button("Cancel") {
              candidate = ""
              isReplacing = false
            }
          }
        }
      }

      if case .error(let message) = status {
        VStack(alignment: .leading, spacing: 5) {
          Label(errorSummary(message), systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .foregroundStyle(.red)
          if message != errorSummary(message) {
            DisclosureGroup("Details", isExpanded: $showsErrorDetails) {
              Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .padding(.top, 3)
            }
            .font(.caption)
          }
          if hasSavedKey {
            Text("Your existing verified key is still active.")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
      }
    }
    .alert("Remove \(kind.label) credential?", isPresented: $confirmsRemoval) {
      Button("Cancel", role: .cancel) {}
      Button("Remove", role: .destructive) {
        model.remove(kind)
        candidate = ""
        isReplacing = false
      }
    } message: {
      Text("AeriVoice will stop using this credential until another key is verified.")
    }
  }

  @ViewBuilder private var credentialStatus: some View {
    switch status {
    case .missing:
      Label("Not connected", systemImage: "circle")
        .foregroundStyle(.secondary)
    case .saved:
      Label("Verified", systemImage: "checkmark.circle.fill")
        .foregroundStyle(.green)
    case .validating:
      HStack(spacing: 6) {
        ProgressView().controlSize(.small)
        Text("Checking…").foregroundStyle(.secondary)
      }
    case .error:
      Label(hasSavedKey ? "Replacement failed" : "Not saved", systemImage: "xmark.circle.fill")
        .foregroundStyle(.red)
    }
  }

  private var description: String {
    switch kind {
    case .soniox:
      "Required for realtime speech transcription. The key is stored only in your Mac’s Keychain."
    case .openRouter:
      "Recommended stable connection for configurable AI transcript cleanup."
    case .groq:
      "Direct Qwen cleanup for evaluation. Models, limits, and behavior may change."
    }
  }

  private func errorSummary(_ message: String) -> String {
    if message.count <= 120 { return message }
    return "AeriVoice couldn’t verify this credential."
  }

  private func verifyAndSave() {
    let value = candidate
    Task {
      await model.validateAndSave(value, kind: kind)
      if model.credentialStatus(for: kind) == .saved {
        candidate = ""
        isReplacing = false
        showsErrorDetails = false
      }
    }
  }
}

struct PermissionStatusRow: View {
  let title: String
  let detail: String
  let granted: Bool
  let actionTitle: String
  let action: () -> Void

  var body: some View {
    HStack(alignment: .center, spacing: 12) {
      Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
        .foregroundStyle(granted ? .green : .orange)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
        Text(detail).font(.caption).foregroundStyle(.secondary)
      }
      Spacer()
      if granted {
        Text("Allowed").foregroundStyle(.secondary)
      } else {
        Button(actionTitle, action: action)
      }
    }
  }
}

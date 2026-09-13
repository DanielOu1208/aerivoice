import SwiftUI

struct SettingsInfoButton: View {
  let title: String
  let message: String
  @State private var showsInfo = false

  var body: some View {
    Button {
      showsInfo.toggle()
    } label: {
      Image(systemName: "info.circle")
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .frame(width: 18, height: 18)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel("About \(title)")
    .help("About \(title)")
    .popover(isPresented: $showsInfo) {
      VStack(alignment: .leading, spacing: 8) {
        Text(title).font(.headline)
        Text(message).foregroundStyle(.secondary)
      }
      .padding(16)
      .frame(width: 300, alignment: .leading)
      .fixedSize(horizontal: false, vertical: true)
    }
  }
}

struct SettingsHelpLabel: View {
  let title: String
  let message: String

  var body: some View {
    HStack(spacing: 4) {
      Text(title)
      SettingsInfoButton(title: title, message: message)
    }
  }
}

struct SettingsControlRow<Control: View>: View {
  let title: String
  let message: String
  @ViewBuilder var control: () -> Control

  var body: some View {
    HStack(spacing: 8) {
      SettingsHelpLabel(title: title, message: message)
      Spacer(minLength: 8)
      control().labelsHidden()
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .contain)
  }
}

struct ProviderIcon: View {
  let kind: CredentialKind

  private var assetName: String {
    switch kind {
    case .soniox: "ProviderSoniox"
    case .metaModelAPI: "ProviderMeta"
    case .openRouter: "ProviderOpenRouter"
    case .groq: "ProviderGroq"
    case .cerebras: "ProviderCerebras"
    }
  }

  var body: some View {
    Image(assetName)
      .resizable()
      .scaledToFit()
      .frame(width: 24, height: 24)
      .clipShape(RoundedRectangle(cornerRadius: 5))
      .accessibilityHidden(true)
  }
}

struct ProviderSelectionRow<Selection: View>: View {
  @ObservedObject var model: AppModel
  let kind: CredentialKind?
  var allowsRemoval = true
  @ViewBuilder var selection: () -> Selection

  var body: some View {
    HStack(spacing: 8) {
      if let kind { ProviderIcon(kind: kind) }
      else { Image(systemName: "desktopcomputer").frame(width: 24, height: 24).accessibilityHidden(true) }
      selection()
        .labelsHidden()
        .pickerStyle(.menu)
        .fixedSize()
      Spacer(minLength: 8)
      if let kind {
        ProviderConnectionControls(model: model, kind: kind, allowsRemoval: allowsRemoval)
      } else if model.localModel.isReady {
        Label("Ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

struct ProviderAccountRow: View {
  @ObservedObject var model: AppModel
  let kind: CredentialKind

  var body: some View {
    HStack(spacing: 10) {
      ProviderIcon(kind: kind)
      Text(kind.label)
      if kind == .groq { ExperimentalBadge() }
      Spacer(minLength: 8)
      ProviderConnectionControls(model: model, kind: kind)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct ProviderConnectionControls: View {
  @ObservedObject var model: AppModel
  let kind: CredentialKind
  var allowsRemoval = true
  @State private var showsCredential = false

  var body: some View {
    CredentialConnectionStatus(model: model, kind: kind)
    Button(model.hasCredential(kind) ? "Manage…" : "Connect…") {
      showsCredential = true
    }
    .accessibilityLabel("\(model.hasCredential(kind) ? "Manage" : "Connect") \(kind.label)")
    .sheet(isPresented: $showsCredential) {
      CredentialSettingsSheet(model: model, kind: kind, allowsRemoval: allowsRemoval)
    }
    .onReceive(model.settingsWindowWillClose) { showsCredential = false }
  }
}

private struct CredentialConnectionStatus: View {
  @ObservedObject var model: AppModel
  let kind: CredentialKind

  var body: some View {
    Group {
      switch model.credentialStatus(for: kind) {
      case .missing:
        Text("Not connected").foregroundStyle(.secondary)
      case .saved:
        Label("Verified", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
      case .validating:
        ProgressView().controlSize(.small).accessibilityLabel("Checking \(kind.label) key")
      case .error:
        Label(
          model.hasCredential(kind) ? "Key needs attention" : "Not connected",
          systemImage: "exclamationmark.circle.fill"
        ).foregroundStyle(.orange)
      }
    }
    .font(.callout)
  }
}

private struct CredentialSettingsSheet: View {
  @ObservedObject var model: AppModel
  let kind: CredentialKind
  let allowsRemoval: Bool
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      CredentialEditorView(model: model, kind: kind, allowsRemoval: allowsRemoval)
      HStack {
        Spacer()
        Button("Done") {
          model.cancelCredentialValidation(kind)
          dismiss()
        }
        .keyboardShortcut(.cancelAction)
      }
    }
    .padding(20)
    .frame(width: 540)
    .fixedSize(horizontal: false, vertical: true)
    .onDisappear { model.cancelCredentialValidation(kind) }
  }
}

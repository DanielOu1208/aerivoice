import SwiftUI

enum SettingsDestination: String, CaseIterable, Hashable, Identifiable {
  case general
  case dictation
  case cleanup
  case providers
  case privacy

  var id: Self { self }

  var title: String {
    switch self {
    case .general: "General"
    case .dictation: "Dictation"
    case .cleanup: "AI Cleanup"
    case .providers: "Providers"
    case .privacy: "Privacy & Data"
    }
  }

  var systemImage: String {
    switch self {
    case .general: "gearshape"
    case .dictation: "waveform"
    case .cleanup: "wand.and.stars"
    case .providers: "key"
    case .privacy: "hand.raised"
    }
  }

  var color: Color {
    switch self {
    case .general: .gray
    case .dictation: .blue
    case .cleanup: .purple
    case .providers: .orange
    case .privacy: .indigo
    }
  }

  @MainActor static func recommended(for model: AppModel) -> Self {
    if model.preferences.shortcut == nil { return .general }
    if !model.transcriptionReady
      || (!model.preferences.offlineMode && !model.hasCredential(model.preferences.cleanupProvider.credentialKind))
    {
      return .providers
    }
    if !model.permissionsReady { return .privacy }
    return .general
  }
}

@MainActor
final class SettingsNavigation: ObservableObject {
  @Published var selection: SettingsDestination

  init(model: AppModel) {
    selection = SettingsDestination.recommended(for: model)
  }
}

struct SettingsSidebar: View {
  @ObservedObject var model: AppModel
  @ObservedObject var navigation: SettingsNavigation
  @ObservedObject private var preferences: AppPreferences

  init(model: AppModel, navigation: SettingsNavigation) {
    self.model = model
    self.navigation = navigation
    preferences = model.preferences
  }

  var body: some View {
    List(SettingsDestination.allCases, selection: $navigation.selection) { destination in
      Label {
        Text(destination.title)
      } icon: {
        Image(systemName: destination.systemImage)
          .font(.system(size: 13, weight: .medium))
          .foregroundStyle(.white)
          .frame(width: 25, height: 25)
          .background(destination.color.gradient, in: RoundedRectangle(cornerRadius: 6))
      }
      .padding(.vertical, 2)
      .tag(destination)
    }
    .listStyle(.sidebar)
    .safeAreaInset(edge: .bottom, spacing: 0) {
      if !model.readinessComplete { readinessFooter }
    }
    .onReceive(model.$settingsDestinationRequest.compactMap { $0 }) {
      navigation.selection = $0
    }
  }

  private var readinessFooter: some View {
    Button {
      navigation.selection = SettingsDestination.recommended(for: model)
    } label: {
      Label("Setup needs attention", systemImage: "exclamationmark.circle.fill")
        .font(.caption)
        .foregroundStyle(.orange)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}

struct SettingsDetail: View {
  @ObservedObject var model: AppModel
  @ObservedObject var navigation: SettingsNavigation

  var body: some View {
    page.frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  @ViewBuilder private var page: some View {
    switch navigation.selection {
    case .general:
      GeneralSettingsPage(model: model)
    case .dictation:
      DictationSettingsPage(model: model, selection: $navigation.selection)
    case .cleanup:
      CleanupSettingsPage(model: model)
    case .providers:
      ProviderSettingsPage(model: model)
    case .privacy:
      PrivacySettingsPage(model: model)
    }
  }
}

struct SettingsToolbarTitle: View {
  @ObservedObject var navigation: SettingsNavigation

  var body: some View {
    Text(navigation.selection.title)
      .font(.system(size: 17, weight: .semibold))
      .accessibilityAddTraits(.isHeader)
      .fixedSize()
      .frame(width: 160, alignment: .leading)
  }
}

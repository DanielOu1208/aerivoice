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

  @MainActor static func recommended(for model: AppModel) -> Self {
    if model.preferences.shortcut == nil { return .general }
    if !model.hasCredential(.soniox)
      || !model.hasCredential(model.preferences.cleanupProvider.credentialKind)
    {
      return .providers
    }
    if !model.permissionsReady { return .privacy }
    return .general
  }
}

struct SettingsRootView: View {
  @ObservedObject var model: AppModel
  @ObservedObject private var preferences: AppPreferences
  let onOnboardingFinished: () -> Void

  init(model: AppModel, onOnboardingFinished: @escaping () -> Void) {
    self.model = model
    self.preferences = model.preferences
    self.onOnboardingFinished = onOnboardingFinished
  }

  var body: some View {
    if preferences.onboardingComplete {
      SettingsView(model: model)
    } else {
      OnboardingView(model: model, onFinished: onOnboardingFinished)
    }
  }
}

struct SettingsView: View {
  @ObservedObject var model: AppModel
  @State private var selection: SettingsDestination

  init(model: AppModel) {
    self.model = model
    _selection = State(initialValue: SettingsDestination.recommended(for: model))
  }

  var body: some View {
    HStack(spacing: 0) {
      ZStack(alignment: .bottom) {
        List(SettingsDestination.allCases, selection: $selection) { destination in
          Label(destination.title, systemImage: destination.systemImage)
            .tag(destination)
        }
        .listStyle(.sidebar)
        VStack(spacing: 0) {
          Divider()
          readinessFooter
        }
      }
      .frame(width: 180)
      .background(.bar)
      Divider()
      detail
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .frame(minWidth: 700, minHeight: 560)
    .onReceive(model.$settingsDestinationRequest.compactMap { $0 }) { selection = $0 }
  }

  @ViewBuilder private var detail: some View {
    switch selection {
    case .general:
      GeneralSettingsPage(model: model)
    case .dictation:
      DictationSettingsPage(model: model, selection: $selection)
    case .cleanup:
      CleanupSettingsPage(model: model, selection: $selection)
    case .providers:
      ProviderSettingsPage(model: model)
    case .privacy:
      PrivacySettingsPage(model: model)
    }
  }

  private var readinessFooter: some View {
    HStack(spacing: 7) {
      Image(
        systemName: model.readinessComplete
          ? "checkmark.circle.fill" : "exclamationmark.circle.fill"
      )
      .foregroundStyle(model.readinessComplete ? .green : .orange)
      Text(model.readinessComplete ? "Ready for dictation" : "Setup needs attention")
        .font(.caption)
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
  }
}

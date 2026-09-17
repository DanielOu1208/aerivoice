import SwiftUI

struct CleanupReasoningPicker: View {
  @ObservedObject var preferences: AppPreferences
  @ObservedObject private var catalog: OpenRouterCatalogStore

  init(preferences: AppPreferences) {
    self.preferences = preferences
    self.catalog = preferences.openRouterCatalog
  }

  private var reasoning: OpenRouterReasoning? {
    catalog.entry(for: preferences.cleanupModel)?.reasoning
  }

  var body: some View {
    SettingsControlRow(title: "Reasoning", message: reasoningDescription) {
      Picker(
        "Reasoning",
        selection: Binding(
          get: { preferences.cleanupReasoningEffort },
          set: { preferences.cleanupReasoningEffort = $0 })
      ) {
        ForEach(preferences.supportedCleanupReasoningEfforts, id: \.self) { effort in
          Text(effortLabel(effort)).tag(effort)
        }
      }
      .labelsHidden()
      .pickerStyle(.menu)
      .disabled(preferences.supportedCleanupReasoningEfforts.count <= 1)
    }

    if preferences.cleanupProvider == .openRouter && preferences.savedCleanupReasoningIsUnavailable
    {
      HStack {
        Label(
          "Saved level unavailable. Using model default.", systemImage: "exclamationmark.circle"
        )
        .foregroundStyle(.orange)
        Spacer()
        Button("Use model default") { preferences.cleanupReasoningEffort = .automatic }
      }
      .font(.caption)
    }
  }

  private var reasoningDescription: String {
    let explanation =
      "Controls how much the model reasons before returning cleaned text. Higher levels can increase response time."
    guard preferences.cleanupProvider == .openRouter else { return explanation }
    if reasoning?.mandatory == true {
      return explanation + " This model requires reasoning."
    }
    if preferences.supportedCleanupReasoningEfforts.count <= 1 {
      return explanation
        + " No reasoning levels are advertised for this model. The model default will be used."
    }
    return explanation + " Available levels are fetched with the model catalog."
  }

  private func effortLabel(_ effort: CleanupReasoningEffort) -> String {
    if effort == .automatic {
      if reasoning?.defaultEnabled == false { return "Model default (off)" }
      if let defaultEffort = reasoning?.defaultEffort {
        return "Model default (\(defaultEffort.displayName))"
      }
    }
    if preferences.cleanupModel == .qwen38_27BCerebras && effort == .none,
      preferences.cleanupMode != .compose,
      preferences.cleanupMode != .custom
    {
      return "None (Recommended)"
    }
    return effort.displayName
  }
}

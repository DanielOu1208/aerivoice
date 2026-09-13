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
    .pickerStyle(.menu)
    .disabled(preferences.supportedCleanupReasoningEfforts.count <= 1)

    if preferences.cleanupProvider == .openRouter {
      if preferences.savedCleanupReasoningIsUnavailable {
        HStack {
          Text("Your saved reasoning level isn’t currently available. Using the model default.")
            .foregroundStyle(.secondary)
          Button("Use model default") { preferences.cleanupReasoningEffort = .automatic }
        }
        .font(.caption)
      } else if reasoning?.mandatory == true {
        Text("This model requires reasoning.")
          .font(.caption).foregroundStyle(.secondary)
      } else if preferences.supportedCleanupReasoningEfforts.count <= 1 {
        Text("No reasoning levels are advertised for this model. The model default will be used.")
          .font(.caption).foregroundStyle(.secondary)
      }
      HStack {
        if catalog.isRefreshing {
          ProgressView().controlSize(.small)
          Text("Refreshing models and reasoning…")
        } else if let fetchedAt = catalog.fetchedAt {
          Text("Catalog updated \(fetchedAt.formatted(date: .abbreviated, time: .shortened))")
        } else {
          Text("Model and reasoning catalog not downloaded")
        }
        Spacer()
        Button("Refresh") { Task { await catalog.refresh(force: true) } }
          .disabled(catalog.isRefreshing)
      }
      .font(.caption).foregroundStyle(.secondary)
      if let errorMessage = catalog.errorMessage {
        Text(errorMessage).font(.caption).foregroundStyle(.secondary)
      }
    }
  }

  private func effortLabel(_ effort: CleanupReasoningEffort) -> String {
    if effort == .automatic {
      if reasoning?.defaultEnabled == false { return "Model default (off)" }
      if let defaultEffort = reasoning?.defaultEffort {
        return "Model default (\(defaultEffort.displayName))"
      }
    }
    if preferences.cleanupModel == .qwen38_27BCerebras && effort == .none {
      return "None (Recommended)"
    }
    return effort.displayName
  }
}

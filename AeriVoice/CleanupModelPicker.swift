import SwiftUI

struct CleanupModelPicker: View {
  @ObservedObject var preferences: AppPreferences
  @ObservedObject private var catalog: OpenRouterCatalogStore
  @Environment(\.dismiss) private var dismiss
  @State private var showsAllModels = false
  @State private var search = ""
  @State private var customID = ""
  init(preferences: AppPreferences) {
    self.preferences = preferences
    self.catalog = preferences.openRouterCatalog
  }

  private var recommended: [CleanupModel] { CleanupProvider.openRouter.models }
  private var matchingEntries: [OpenRouterCatalogEntry] {
    catalog.entries.filter { $0.matches(search) }
  }
  private var customModel: CleanupModel? {
    CleanupModel(openRouterID: customID.trimmingCharacters(in: .whitespacesAndNewlines))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        Text("Cleanup Model").font(.headline)
        SettingsInfoButton(
          title: "Cleanup models",
          message:
            "Recommended presets have configured reasoning and provider settings. The full catalog contains compatible text models; speed, cost, and cleanup quality vary."
        )
        Spacer()
        Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
      }
      Picker("Model list", selection: $showsAllModels) {
        Text("Recommended").tag(false)
        Text("All compatible models").tag(true)
      }
      .pickerStyle(.segmented)

      if showsAllModels {
        TextField("Search model names or IDs", text: $search)
          .textFieldStyle(.roundedBorder)
          .multilineTextAlignment(.leading)
      }

      catalogStatus

      ScrollView {
        LazyVStack(alignment: .leading, spacing: 0) {
          if showsAllModels {
            ForEach(matchingEntries) { entry in
              if let model = entry.cleanupModel {
                modelRow(model, name: entry.name)
              }
            }
            if matchingEntries.isEmpty && !catalog.isRefreshing {
              Text(
                catalog.errorMessage == nil
                  ? "No matching models." : "Choose a preset or enter a model ID below."
              )
              .foregroundStyle(.secondary).padding(.vertical)
            }
          } else {
            ForEach(recommended, id: \.self) { model in
              modelRow(model, name: model.displayName)
            }
          }
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

      if showsAllModels {
        Divider()
        HStack {
          TextField("Custom text model ID (author/model)", text: $customID)
            .textFieldStyle(.roundedBorder)
            .onSubmit { selectCustomModel() }
          Button("Use model") { selectCustomModel() }
            .disabled(customModel == nil)
        }
      }

      Text(
        "Selected: \(catalog.entry(for: preferences.cleanupModel)?.name ?? preferences.cleanupModel.displayName)"
      )
      .font(.caption).foregroundStyle(.secondary)
      .textSelection(.enabled)
    }
    .padding(20)
    .frame(width: 580, height: 530)
    .task { await catalog.refresh() }
  }

  private var catalogStatus: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        if catalog.isRefreshing {
          ProgressView().controlSize(.small)
          Text("Refreshing catalog…")
        } else if let fetchedAt = catalog.fetchedAt {
          Text("Updated \(fetchedAt.formatted(date: .abbreviated, time: .shortened))")
        } else {
          Text("Catalog not downloaded")
        }
        Spacer()
        Button("Refresh", systemImage: "arrow.clockwise") {
          Task { await catalog.refresh(force: true) }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .help("Refresh models and reasoning")
        .disabled(catalog.isRefreshing)
      }
      if let errorMessage = catalog.errorMessage {
        Text(errorMessage).fixedSize(horizontal: false, vertical: true)
      }
    }
    .font(.caption).foregroundStyle(.secondary)
  }

  private func modelRow(_ model: CleanupModel, name: String) -> some View {
    Button {
      preferences.cleanupModel = model
      dismiss()
    } label: {
      HStack {
        VStack(alignment: .leading, spacing: 3) {
          Text(name).foregroundStyle(.primary)
          Text(model.rawValue).font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        if preferences.cleanupModel == model {
          Image(systemName: "checkmark").foregroundStyle(.tint)
        }
      }
      .padding(10)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel("\(name), \(model.rawValue)")
    .accessibilityAddTraits(preferences.cleanupModel == model ? .isSelected : [])
  }

  private func selectCustomModel() {
    guard let customModel else { return }
    preferences.cleanupModel = customModel
    dismiss()
  }

}

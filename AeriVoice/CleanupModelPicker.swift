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
        Text("Choose a cleanup model").font(.title2.bold())
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
        HStack {
          Text("Text models only. Speed, cost, and cleanup quality vary.")
            .font(.caption).foregroundStyle(.secondary)
          Spacer()
          if catalog.isRefreshing { ProgressView().controlSize(.small) }
          Button("Refresh", systemImage: "arrow.clockwise") {
            Task { await catalog.refresh(force: true) }
          }
          .labelStyle(.iconOnly)
          .disabled(catalog.isRefreshing)
        }
        if let errorMessage = catalog.errorMessage {
          Text(errorMessage).font(.caption).foregroundStyle(.secondary)
        }
      } else {
        Text("Presets with configured reasoning and provider settings.")
          .font(.caption).foregroundStyle(.secondary)
      }

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
        Text("For text models missing from the list. Availability is checked when cleanup runs.")
          .font(.caption).foregroundStyle(.secondary)
      }
      Text("Selected: \(preferences.cleanupModel.displayName)")
        .font(.caption).foregroundStyle(.secondary)
        .textSelection(.enabled)
    }
    .padding(20)
    .frame(width: 580, height: 530)
    .task { await catalog.refresh() }
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

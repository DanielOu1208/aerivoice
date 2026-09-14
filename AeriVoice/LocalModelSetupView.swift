import SwiftUI

struct LocalModelSetupView: View {
  @ObservedObject var controller: LocalModelController
  var offline = false
  var allowsPreparation = true
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Nemotron 3.5 — English").font(.headline)
      Text(offline ? "Transcribes audio on this Mac. AI cleanup is off." : "Transcribes audio on this Mac. No transcription API key needed. AI cleanup settings still apply unless Offline mode is enabled.")
        .font(.caption).foregroundStyle(.secondary)
      switch controller.state {
      case .missing:
        Button("Download model · 611 MB") { controller.download() }.disabled(offline)
      case .available:
        Label("Downloaded", systemImage: "internaldrive")
        if allowsPreparation {
          Button("Prepare model") { controller.prepareIfNeeded() }
        } else {
          Text("Select Local or enable Offline mode to prepare this model.")
            .font(.caption).foregroundStyle(.secondary)
        }
        removeButton
      case .preparing:
        ProgressView("Preparing Local model…")
      case .ready:
        Label("Ready · works offline", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        removeButton
      case .downloading(let progress):
        ProgressView("Downloading model…", value: progress)
        Button("Cancel download") { controller.cancelDownload() }
      case .failed(let message):
        Text(message).font(.caption).foregroundStyle(.red)
        Button("Retry preparation") { controller.prepareIfNeeded() }.disabled(!allowsPreparation)
        Button("Retry download") { controller.download() }.disabled(offline)
        removeButton
      }
    }
  }
  private var removeButton: some View {
    Button("Remove downloaded model", role: .destructive) { controller.remove() }
      .disabled(offline || !controller.canRemove)
  }
}

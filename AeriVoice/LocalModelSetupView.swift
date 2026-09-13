import SwiftUI

struct LocalModelSetupView: View {
  @ObservedObject var controller: LocalModelController
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Nemotron 3.5 — English").font(.headline)
      Text("Transcribes audio on this Mac. No account or transcription API key needed. Existing AI cleanup settings still apply to the text.")
        .font(.caption).foregroundStyle(.secondary)
      switch controller.state {
      case .missing:
        Button("Download model · 611 MB") { controller.download() }
      case .available:
        Label("Downloaded", systemImage: "internaldrive")
        Button("Prepare model") { controller.prepareIfNeeded() }
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
        Button("Retry download / preparation") { controller.download() }
        removeButton
      }
    }
  }
  private var removeButton: some View {
    Button("Remove downloaded model", role: .destructive) { controller.remove() }
      .disabled(!controller.canRemove)
  }
}

import Foundation

extension AppModel {
  var selectedLocalModelReady: Bool {
    preferences.localTranscriptionModel == .apple ? appleSpeech.isReady : localModel.isReady
  }

  var selectedLocalAssetsInstalled: Bool {
    preferences.localTranscriptionModel == .apple
      ? appleSpeech.assetsInstalled : localModel.assetsInstalled
  }

  var canChangeOfflineMode: Bool {
    !coordinator.canCancel && !changingOfflineMode && !appleSpeech.isDownloading
      && (preferences.offlineMode || selectedLocalAssetsInstalled)
  }

  var offlineModeExplanation: String {
    if changingOfflineMode { return "Switching mode…" }
    if coordinator.canCancel { return "Finish or cancel dictation to switch modes." }
    if appleSpeech.isDownloading { return "Wait for the Apple language download to finish." }
    if preferences.offlineMode { return "Uses local transcription. AI cleanup is off." }
    if !selectedLocalAssetsInstalled { return "Requires local model setup." }
    return "Keeps AeriVoice offline and turns off AI cleanup."
  }

  func showLocalSetup() {
    localSetupRequested = true
    settingsDestinationRequest = .dictation
  }

  func setLocalTranscriptionModel(_ value: LocalTranscriptionModel) {
    guard !coordinator.canCancel, !changingOfflineMode else { return }
    if preferences.offlineMode {
      let installed = value == .apple ? appleSpeech.assetsInstalled : localModel.assetsInstalled
      guard installed else { return }
    }
    preferences.localTranscriptionModel = value
  }
}

import AppKit

enum DictationCue: String, CaseIterable {
  case start = "dictation-start"
  case stop = "dictation-stop"
  case error = "dictation-error"
}

@MainActor
protocol SoundCuePlaying: AnyObject {
  var startCaptureDelay: Duration { get }
  func play(_ cue: DictationCue)
}

@MainActor
final class SoundCuePlayer: SoundCuePlaying {
  let startCaptureDelay: Duration = .milliseconds(300)

  private let sounds: [DictationCue: NSSound]

  init() {
    sounds = Dictionary(
      uniqueKeysWithValues: DictationCue.allCases.compactMap { cue in
        guard let sound = NSSound(named: Self.nativeSoundName(for: cue)) else { return nil }
        return (cue, sound)
      })
  }

  func play(_ cue: DictationCue) {
    guard let sound = sounds[cue] else { return }
    sound.stop()
    sound.play()
  }

  static func nativeSoundName(for cue: DictationCue) -> NSSound.Name {
    switch cue {
    case .start: NSSound.Name("Blow")
    case .stop: NSSound.Name("Bottle")
    case .error: NSSound.Name("Submarine")
    }
  }
}

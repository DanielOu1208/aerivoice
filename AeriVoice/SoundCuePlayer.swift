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
  let startCaptureDelay: Duration = .milliseconds(140)

  private let sounds: [DictationCue: NSSound]

  init(bundle: Bundle = .main) {
    sounds = Dictionary(
      uniqueKeysWithValues: DictationCue.allCases.compactMap { cue in
        guard let url = Self.resourceURL(for: cue, in: bundle),
          let sound = NSSound(contentsOf: url, byReference: false)
        else { return nil }
        return (cue, sound)
      })
  }

  func play(_ cue: DictationCue) {
    guard let sound = sounds[cue] else { return }
    sound.stop()
    sound.play()
  }

  static func resourceURL(for cue: DictationCue, in bundle: Bundle) -> URL? {
    bundle.url(forResource: cue.rawValue, withExtension: "wav", subdirectory: "Sounds")
      ?? bundle.url(forResource: cue.rawValue, withExtension: "wav")
  }
}

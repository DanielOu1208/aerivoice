import Foundation
import ServiceManagement

@MainActor
final class AppPreferences: ObservableObject {
  private enum Key {
    static let cleanupMode = "cleanupMode"
    static let vocabulary = "vocabulary"
    static let muteOutput = "muteOutput"
    static let soundCues = "soundCues"
    static let shortcut = "shortcut"
    static let onboardingComplete = "onboardingComplete"
    static let launchAtLogin = "launchAtLogin"
    static let latencyLogging = "latencyLogging"
  }

  @Published var cleanupMode: CleanupMode {
    didSet { defaults.set(cleanupMode.rawValue, forKey: Key.cleanupMode) }
  }
  @Published var vocabulary: String { didSet { defaults.set(vocabulary, forKey: Key.vocabulary) } }
  @Published var muteOutput: Bool { didSet { defaults.set(muteOutput, forKey: Key.muteOutput) } }
  @Published var soundCues: Bool { didSet { defaults.set(soundCues, forKey: Key.soundCues) } }
  @Published var shortcut: ShortcutDefinition? { didSet { persistShortcut() } }
  @Published var onboardingComplete: Bool {
    didSet { defaults.set(onboardingComplete, forKey: Key.onboardingComplete) }
  }
  @Published var launchAtLogin: Bool
  @Published var latencyLogging: Bool {
    didSet { defaults.set(latencyLogging, forKey: Key.latencyLogging) }
  }

  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    cleanupMode = CleanupMode(rawValue: defaults.string(forKey: Key.cleanupMode) ?? "") ?? .faithful
    vocabulary = defaults.string(forKey: Key.vocabulary) ?? ""
    muteOutput = defaults.object(forKey: Key.muteOutput) as? Bool ?? true
    soundCues = defaults.object(forKey: Key.soundCues) as? Bool ?? true
    onboardingComplete = defaults.bool(forKey: Key.onboardingComplete)
    launchAtLogin = defaults.object(forKey: Key.launchAtLogin) as? Bool ?? true
    latencyLogging = defaults.object(forKey: Key.latencyLogging) as? Bool ?? true
    if let data = defaults.data(forKey: Key.shortcut) {
      shortcut = try? JSONDecoder().decode(ShortcutDefinition.self, from: data)
    }
  }

  func setLaunchAtLogin(_ enabled: Bool) {
    defaults.set(enabled, forKey: Key.launchAtLogin)
    do {
      if enabled {
        try SMAppService.mainApp.register()
      } else {
        try SMAppService.mainApp.unregister()
      }
      launchAtLogin = enabled
    } catch {
      launchAtLogin = SMAppService.mainApp.status == .enabled
    }
  }

  private func persistShortcut() {
    if let shortcut, let data = try? JSONEncoder().encode(shortcut) {
      defaults.set(data, forKey: Key.shortcut)
    } else {
      defaults.removeObject(forKey: Key.shortcut)
    }
  }
}

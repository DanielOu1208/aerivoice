import Foundation
import ServiceManagement

@MainActor
protocol LoginItemManaging {
  var status: LoginItemStatus { get }
  func setEnabled(_ enabled: Bool) throws
}

enum LoginItemStatus: Equatable {
  case disabled
  case enabled
  case requiresApproval

  var isRegistered: Bool { self != .disabled }
}

struct MainAppLoginItemManager: LoginItemManaging {
  var status: LoginItemStatus {
    switch SMAppService.mainApp.status {
    case .enabled: .enabled
    case .requiresApproval: .requiresApproval
    default: .disabled
    }
  }

  func setEnabled(_ enabled: Bool) throws {
    if enabled {
      guard status == .disabled else { return }
      try SMAppService.mainApp.register()
    } else {
      guard status.isRegistered else { return }
      try SMAppService.mainApp.unregister()
    }
  }
}

@MainActor
final class AppPreferences: ObservableObject {
  private enum Key {
    static let transcriptionProvider = "transcriptionProvider"
    static let cleanupMode = "cleanupMode"
    static let cleanupProvider = "cleanupProvider"
    static let cleanupModel = "cleanupModel"
    static let cleanupModels = "cleanupModels"
    static let cleanupReasoningEfforts = "cleanupReasoningEfforts"
    static let vocabulary = "vocabulary"
    static let muteOutput = "muteOutput"
    static let soundCues = "soundCues"
    static let shortcut = "shortcut"
    static let shortcutActivationMode = "shortcutActivationMode"
    static let onboardingComplete = "onboardingComplete"
    static let launchAtLogin = "launchAtLogin"
    static let latencyLogging = "latencyLogging"
  }

  @Published var transcriptionProvider: TranscriptionProvider {
    didSet {
      defaults.set(transcriptionProvider.rawValue, forKey: Key.transcriptionProvider)
      RealtimeTranscriptionPrewarmer.prewarm(provider: transcriptionProvider)
    }
  }
  @Published var cleanupMode: CleanupMode {
    didSet { defaults.set(cleanupMode.rawValue, forKey: Key.cleanupMode) }
  }
  @Published var cleanupProvider: CleanupProvider {
    didSet {
      defaults.set(cleanupProvider.rawValue, forKey: Key.cleanupProvider)
      let model = selectedModel(for: cleanupProvider)
      savedModels[cleanupProvider.rawValue] = model.rawValue
      defaults.set(model.rawValue, forKey: Key.cleanupModel)
      persistModels()
    }
  }
  @Published var vocabulary: String { didSet { defaults.set(vocabulary, forKey: Key.vocabulary) } }
  @Published var muteOutput: Bool { didSet { defaults.set(muteOutput, forKey: Key.muteOutput) } }
  @Published var soundCues: Bool { didSet { defaults.set(soundCues, forKey: Key.soundCues) } }
  @Published var shortcut: ShortcutDefinition? { didSet { persistShortcut() } }
  @Published var shortcutActivationMode: ShortcutActivationMode {
    didSet { defaults.set(shortcutActivationMode.rawValue, forKey: Key.shortcutActivationMode) }
  }
  @Published var onboardingComplete: Bool {
    didSet { defaults.set(onboardingComplete, forKey: Key.onboardingComplete) }
  }
  @Published var launchAtLogin: Bool
  @Published var latencyLogging: Bool {
    didSet { defaults.set(latencyLogging, forKey: Key.latencyLogging) }
  }

  private let defaults: UserDefaults
  private let loginItemManager: LoginItemManaging
  private var savedModels: [String: String] = [:]
  private var savedReasoningEfforts: [String: String] = [:]

  var cleanupModel: CleanupModel {
    get { selectedModel(for: cleanupProvider) }
    set {
      guard newValue != cleanupModel else { return }
      let providerChanged = newValue.provider != cleanupProvider
      if !providerChanged { objectWillChange.send() }
      savedModels[newValue.provider.rawValue] = newValue.rawValue
      defaults.set(newValue.rawValue, forKey: Key.cleanupModel)
      persistModels()
      if providerChanged { cleanupProvider = newValue.provider }
    }
  }

  var cleanupReasoningEffort: CleanupReasoningEffort {
    get {
      let saved = savedReasoningEfforts[cleanupModel.rawValue].flatMap {
        CleanupReasoningEffort(rawValue: $0)
      }
      return cleanupModel.normalizedReasoningEffort(saved)
    }
    set {
      let normalized = cleanupModel.normalizedReasoningEffort(newValue)
      guard cleanupReasoningEffort != normalized else { return }
      objectWillChange.send()
      savedReasoningEfforts[cleanupModel.rawValue] = normalized.rawValue
      persistReasoningEfforts()
    }
  }

  var cleanupConfiguration: CleanupConfiguration {
    CleanupConfiguration(model: cleanupModel, reasoningEffort: cleanupReasoningEffort)
  }

  func cleanupConfiguration(for provider: CleanupProvider) -> CleanupConfiguration {
    let model = selectedModel(for: provider)
    let effort = savedReasoningEfforts[model.rawValue].flatMap(CleanupReasoningEffort.init)
    return CleanupConfiguration(
      model: model, reasoningEffort: model.normalizedReasoningEffort(effort))
  }

  init(
    defaults: UserDefaults = .standard,
    loginItemManager: LoginItemManaging = MainAppLoginItemManager()
  ) {
    self.defaults = defaults
    self.loginItemManager = loginItemManager
    transcriptionProvider =
      TranscriptionProvider(
        rawValue: defaults.string(forKey: Key.transcriptionProvider) ?? "") ?? .soniox
    cleanupMode = CleanupMode(rawValue: defaults.string(forKey: Key.cleanupMode) ?? "") ?? .faithful
    let legacyModel =
      CleanupModel(rawValue: defaults.string(forKey: Key.cleanupModel) ?? "") ?? .defaultModel
    if let data = defaults.data(forKey: Key.cleanupModels),
      let saved = try? JSONDecoder().decode([String: String].self, from: data)
    {
      savedModels = saved
    }
    savedModels[legacyModel.provider.rawValue] = legacyModel.rawValue
    let initialProvider =
      CleanupProvider(rawValue: defaults.string(forKey: Key.cleanupProvider) ?? "")
      ?? legacyModel.provider
    let initialModel =
      savedModels[initialProvider.rawValue].flatMap(CleanupModel.init)
      .flatMap { $0.provider == initialProvider ? $0 : nil }
      ?? initialProvider.defaultModel
    savedModels[initialProvider.rawValue] = initialModel.rawValue
    cleanupProvider = initialProvider
    if let data = defaults.data(forKey: Key.cleanupReasoningEfforts),
      let saved = try? JSONDecoder().decode([String: String].self, from: data)
    {
      savedReasoningEfforts = saved
    }
    vocabulary = defaults.string(forKey: Key.vocabulary) ?? ""
    muteOutput = defaults.object(forKey: Key.muteOutput) as? Bool ?? true
    soundCues = defaults.object(forKey: Key.soundCues) as? Bool ?? true
    shortcutActivationMode =
      ShortcutActivationMode(rawValue: defaults.string(forKey: Key.shortcutActivationMode) ?? "")
      ?? .hybrid
    onboardingComplete = defaults.bool(forKey: Key.onboardingComplete)
    launchAtLogin = defaults.object(forKey: Key.launchAtLogin) as? Bool ?? true
    latencyLogging = defaults.object(forKey: Key.latencyLogging) as? Bool ?? true
    if let data = defaults.data(forKey: Key.shortcut) {
      shortcut = try? JSONDecoder().decode(ShortcutDefinition.self, from: data)
    }
    defaults.set(initialProvider.rawValue, forKey: Key.cleanupProvider)
    defaults.set(initialModel.rawValue, forKey: Key.cleanupModel)
    defaults.set(transcriptionProvider.rawValue, forKey: Key.transcriptionProvider)
    persistModels()
  }

  @discardableResult
  func setLaunchAtLogin(_ enabled: Bool) -> Bool {
    do {
      try loginItemManager.setEnabled(enabled)
    } catch {
      launchAtLogin = loginItemManager.status.isRegistered
      defaults.set(launchAtLogin, forKey: Key.launchAtLogin)
      return false
    }
    launchAtLogin = loginItemManager.status.isRegistered
    defaults.set(launchAtLogin, forKey: Key.launchAtLogin)
    return launchAtLogin == enabled
  }

  private func persistShortcut() {
    if let shortcut, let data = try? JSONEncoder().encode(shortcut) {
      defaults.set(data, forKey: Key.shortcut)
    } else {
      defaults.removeObject(forKey: Key.shortcut)
    }
  }

  private func persistReasoningEfforts() {
    if let data = try? JSONEncoder().encode(savedReasoningEfforts) {
      defaults.set(data, forKey: Key.cleanupReasoningEfforts)
    }
  }

  private func selectedModel(for provider: CleanupProvider) -> CleanupModel {
    savedModels[provider.rawValue].flatMap(CleanupModel.init)
      .flatMap { $0.provider == provider ? $0 : nil }
      ?? provider.defaultModel
  }

  private func persistModels() {
    if let data = try? JSONEncoder().encode(savedModels) {
      defaults.set(data, forKey: Key.cleanupModels)
    }
  }
}

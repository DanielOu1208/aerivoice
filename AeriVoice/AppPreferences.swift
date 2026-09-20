import Combine
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
    static let offlineMode = "offlineMode"
    static let localTranscriptionModel = "localTranscriptionModel"
    static let appleSpeechLocale = "appleSpeechLocale"
    static let transcriptionProvider = "transcriptionProvider"
    static let cleanupMode = "cleanupMode"
    static let cleanupCustomInstructions = "cleanupCustomInstructions"
    static let cleanupProvider = "cleanupProvider"
    static let catalogRequiresZeroDataRetention = "catalogRequiresZeroDataRetention"
    static let cleanupModel = "cleanupModel"
    static let cleanupModels = "cleanupModels"
    static let cleanupReasoningEfforts = "cleanupReasoningEfforts"
    static let vocabulary = "vocabulary"
    static let muteOutput = "muteOutput"
    static let soundCues = "soundCues"
    static let restoreClipboard = "restoreClipboard"
    static let shortcut = "shortcut"
    static let shortcutActivationMode = "shortcutActivationMode"
    static let onboardingComplete = "onboardingComplete"
    static let launchAtLogin = "launchAtLogin"
    static let latencyLogging = "latencyLogging"
    static let diagnosticsGeneration = "diagnosticsGeneration"
    static let diagnosticsRevoked = "diagnosticsRevoked"
  }

  @Published private(set) var offlineMode: Bool
  @Published var localTranscriptionModel: LocalTranscriptionModel {
    didSet {
      defaults.set(localTranscriptionModel.rawValue, forKey: Key.localTranscriptionModel)
      onTranscriptionProviderChange?()
    }
  }
  @Published var appleSpeechLocale: String {
    didSet {
      defaults.set(appleSpeechLocale, forKey: Key.appleSpeechLocale)
      onTranscriptionProviderChange?()
    }
  }

  var effectiveTranscriptionProvider: TranscriptionProvider { offlineMode ? .local : transcriptionProvider }
  var transcriptionConfiguration: TranscriptionConfiguration {
    TranscriptionConfiguration(provider: effectiveTranscriptionProvider,
      localModel: localTranscriptionModel, appleLocaleIdentifier: appleSpeechLocale)
  }

  func setOfflineMode(_ enabled: Bool) {
    offlineMode = enabled
    defaults.set(enabled, forKey: Key.offlineMode)
    onTranscriptionProviderChange?()
  }

  @Published var transcriptionProvider: TranscriptionProvider {
    didSet {
      defaults.set(transcriptionProvider.rawValue, forKey: Key.transcriptionProvider)
      if let onTranscriptionProviderChange { onTranscriptionProviderChange() }
      else if !offlineMode { RealtimeTranscriptionPrewarmer.prewarm(provider: transcriptionProvider) }
    }
  }
  @Published var cleanupMode: CleanupMode {
    didSet { defaults.set(cleanupMode.rawValue, forKey: Key.cleanupMode) }
  }
  @Published var cleanupCustomInstructions: String {
    didSet { defaults.set(cleanupCustomInstructions, forKey: Key.cleanupCustomInstructions) }
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
  @Published var catalogRequiresZeroDataRetention: Bool {
    didSet {
      defaults.set(catalogRequiresZeroDataRetention, forKey: Key.catalogRequiresZeroDataRetention)
    }
  }
  var onVocabularyChange: (() -> Void)?
  @Published var vocabulary: String {
    didSet {
      defaults.set(vocabulary, forKey: Key.vocabulary)
      if oldValue != vocabulary { onVocabularyChange?() }
    }
  }
  @Published var muteOutput: Bool { didSet { defaults.set(muteOutput, forKey: Key.muteOutput) } }
  @Published var soundCues: Bool { didSet { defaults.set(soundCues, forKey: Key.soundCues) } }
  @Published var restoreClipboard: Bool {
    didSet {
      defaults.set(restoreClipboard, forKey: Key.restoreClipboard)
      onClipboardRestorationChange?(restoreClipboard)
    }
  }
  @Published var shortcut: ShortcutDefinition? { didSet { persistShortcut() } }
  @Published var shortcutActivationMode: ShortcutActivationMode {
    didSet { defaults.set(shortcutActivationMode.rawValue, forKey: Key.shortcutActivationMode) }
  }
  @Published var onboardingComplete: Bool {
    didSet { defaults.set(onboardingComplete, forKey: Key.onboardingComplete) }
  }
  @Published var launchAtLogin: Bool
  @Published var latencyLogging: Bool {
    didSet {
      if !latencyLogging, oldValue {
        defaults.set(UUID().uuidString, forKey: Key.diagnosticsGeneration)
        defaults.set(true, forKey: Key.diagnosticsRevoked)
      }
      defaults.set(latencyLogging, forKey: Key.latencyLogging)
      onDiagnosticsLoggingChange?(latencyLogging)
    }
  }

  var onClipboardRestorationChange: ((Bool) -> Void)?
  var onDiagnosticsLoggingChange: ((Bool) -> Void)?
  var onTranscriptionProviderChange: (() -> Void)?
  var diagnosticsGeneration: UUID? {
    defaults.string(forKey: Key.diagnosticsGeneration).flatMap(UUID.init(uuidString:))
  }
  var acceptsLegacyDiagnosticCheckpoint: Bool { !defaults.bool(forKey: Key.diagnosticsRevoked) }

  let openRouterCatalog: OpenRouterCatalogStore
  private var catalogObservation: AnyCancellable?

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

  var supportedCleanupReasoningEfforts: [CleanupReasoningEffort] {
    supportedReasoningEfforts(for: cleanupModel)
  }

  var cleanupReasoningEffort: CleanupReasoningEffort {
    get { effectiveReasoningEffort(for: cleanupModel) }
    set {
      let normalized = cleanupModel.normalizedReasoningEffort(
        newValue, supportedEfforts: supportedCleanupReasoningEfforts)
      // Allow an explicit Model default choice to replace a saved, unavailable level.
      guard savedReasoningEffort(for: cleanupModel) != normalized else { return }
      objectWillChange.send()
      savedReasoningEfforts[reasoningKey(for: cleanupModel)] = normalized.rawValue
      persistReasoningEfforts()
    }
  }

  var savedCleanupReasoningIsUnavailable: Bool {
    guard let saved = savedReasoningEffort(for: cleanupModel) else { return false }
    return !supportedCleanupReasoningEfforts.contains(saved)
  }

  var cleanupConfiguration: CleanupConfiguration {
    cleanupConfiguration(for: cleanupProvider)
  }

  func cleanupConfiguration(for provider: CleanupProvider) -> CleanupConfiguration {
    let model = selectedModel(for: provider)
    return CleanupConfiguration(
      model: model, reasoningEffort: effectiveReasoningEffort(for: model),
      catalogRequiresZeroDataRetention: catalogRequiresZeroDataRetention,
      supportedReasoningEfforts: supportedReasoningEfforts(for: model))
  }

  private func reasoningKey(for model: CleanupModel) -> String {
    "\(model.provider.rawValue):\(model.rawValue)"
  }

  private func savedReasoningEffort(for model: CleanupModel) -> CleanupReasoningEffort? {
    if let value = savedReasoningEfforts[reasoningKey(for: model)] {
      return CleanupReasoningEffort(rawValue: value)
    }
    // Legacy keys lacked a provider. Preserve their original route instead of
    // inheriting a direct provider's choice for an OpenRouter model with the same ID.
    guard CleanupModel(rawValue: model.rawValue)?.provider == model.provider else { return nil }
    return savedReasoningEfforts[model.rawValue].flatMap(CleanupReasoningEffort.init(rawValue:))
  }

  private func supportedReasoningEfforts(for model: CleanupModel) -> [CleanupReasoningEffort] {
    if let entry = openRouterCatalog.entry(for: model) {
      return [.automatic] + (entry.reasoning?.selectableEfforts ?? [])
    }
    let fallback = model.supportedReasoningEfforts
    if model.provider == .openRouter {
      return [.automatic] + fallback.filter { $0 != .automatic }
    }
    return fallback
  }

  private func effectiveReasoningEffort(for model: CleanupModel) -> CleanupReasoningEffort {
    let available = supportedReasoningEfforts(for: model)
    if let saved = savedReasoningEffort(for: model), !available.contains(saved) {
      // Retain the saved preference so a temporary catalog change does not erase it.
      return available.contains(.automatic) ? .automatic : model.defaultReasoningEffort
    }
    return model.normalizedReasoningEffort(
      savedReasoningEffort(for: model), supportedEfforts: available)
  }

  init(
    defaults: UserDefaults = .standard,
    loginItemManager: LoginItemManaging = MainAppLoginItemManager(),
    openRouterCatalog: OpenRouterCatalogStore? = nil
  ) {
    // Separate preference suites must explicitly opt into a shared disk cache.
    self.openRouterCatalog =
      openRouterCatalog
      ?? OpenRouterCatalogStore(
        cacheURL: defaults === UserDefaults.standard ? OpenRouterCatalogStore.defaultCacheURL : nil)
    self.defaults = defaults
    self.loginItemManager = loginItemManager
    offlineMode = defaults.bool(forKey: Key.offlineMode)
    localTranscriptionModel = LocalTranscriptionModel(rawValue: defaults.string(forKey: Key.localTranscriptionModel) ?? "") ?? .nemotron
    appleSpeechLocale = defaults.string(forKey: Key.appleSpeechLocale) ?? ""
    transcriptionProvider =
      TranscriptionProvider(
        rawValue: defaults.string(forKey: Key.transcriptionProvider) ?? "") ?? .soniox
    cleanupCustomInstructions = defaults.string(forKey: Key.cleanupCustomInstructions) ?? ""
    cleanupMode = CleanupMode(rawValue: defaults.string(forKey: Key.cleanupMode) ?? "") ?? .polished
    let savedProvider = CleanupProvider(
      rawValue: defaults.string(forKey: Key.cleanupProvider) ?? "")
    let legacyID = defaults.string(forKey: Key.cleanupModel) ?? ""
    let legacyModel =
      savedProvider.flatMap { CleanupModel.saved(legacyID, for: $0) }
      ?? CleanupModel(rawValue: legacyID) ?? .defaultModel
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
      savedModels[initialProvider.rawValue].flatMap { CleanupModel.saved($0, for: initialProvider) }
      ?? initialProvider.defaultModel
    savedModels[initialProvider.rawValue] = initialModel.rawValue
    cleanupProvider = initialProvider
    if let data = defaults.data(forKey: Key.cleanupReasoningEfforts),
      let saved = try? JSONDecoder().decode([String: String].self, from: data)
    {
      savedReasoningEfforts = saved
    }
    catalogRequiresZeroDataRetention =
      defaults.object(forKey: Key.catalogRequiresZeroDataRetention) as? Bool ?? true
    vocabulary = defaults.string(forKey: Key.vocabulary) ?? ""
    muteOutput = defaults.object(forKey: Key.muteOutput) as? Bool ?? true
    soundCues = defaults.object(forKey: Key.soundCues) as? Bool ?? true
    restoreClipboard = defaults.object(forKey: Key.restoreClipboard) as? Bool ?? true
    shortcutActivationMode =
      ShortcutActivationMode(rawValue: defaults.string(forKey: Key.shortcutActivationMode) ?? "")
      ?? .hybrid
    onboardingComplete = defaults.bool(forKey: Key.onboardingComplete)
    launchAtLogin = defaults.object(forKey: Key.launchAtLogin) as? Bool ?? true
    latencyLogging = defaults.object(forKey: Key.latencyLogging) as? Bool ?? false
    if defaults.string(forKey: Key.diagnosticsGeneration).flatMap(UUID.init(uuidString:)) == nil {
      defaults.set(UUID().uuidString, forKey: Key.diagnosticsGeneration)
    }
    if let data = defaults.data(forKey: Key.shortcut) {
      shortcut = try? JSONDecoder().decode(ShortcutDefinition.self, from: data)
    }
    defaults.set(initialProvider.rawValue, forKey: Key.cleanupProvider)
    defaults.set(initialModel.rawValue, forKey: Key.cleanupModel)
    defaults.set(transcriptionProvider.rawValue, forKey: Key.transcriptionProvider)
    persistModels()
    catalogObservation = self.openRouterCatalog.objectWillChange.sink { [weak self] _ in
      self?.objectWillChange.send()
    }
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
    savedModels[provider.rawValue].flatMap { CleanupModel.saved($0, for: provider) }
      ?? provider.defaultModel
  }

  private func persistModels() {
    if let data = try? JSONEncoder().encode(savedModels) {
      defaults.set(data, forKey: Key.cleanupModels)
    }
  }
}

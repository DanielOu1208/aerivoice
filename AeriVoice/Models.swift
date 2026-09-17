import AppKit
import Foundation

enum DictationPhase: Equatable, Sendable {
  case idle
  case starting
  case recording
  case processing
  case cleaning
  case inserting
  case success
  case error(String)
}

struct DictationSessionID: Hashable, Sendable {
  let rawValue: UUID
  init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
}

struct TranscriptSnapshot: Equatable, Sendable {
  var confirmed = ""
  var provisional = ""

  var displayText: String { confirmed + provisional }
}

struct RealtimeTranscriptUpdate: Equatable, Sendable {
  let snapshot: TranscriptSnapshot
  let hasFinalText: Bool
  let finalAudioProcessedMS: Double?
  let totalAudioProcessedMS: Double?
}

struct RealtimeAudioFrame: Equatable, Sendable {
  let audio: Data
  let queuedBytesAfterFrame: Int
}

enum TranscriptionProvider: String, CaseIterable, Codable, Identifiable, Sendable {
  case soniox
  case meta
  case local

  var id: Self { self }

  var displayName: String {
    switch self {
    case .soniox: "Soniox"
    case .meta: "Meta"
    case .local: "Local"
    }
  }

  var modelDisplayName: String {
    switch self {
    case .soniox: "Soniox Realtime"
    case .meta: "Muse Voice Transcribe 1.0"
    case .local: "Nemotron 3.5 — English"
    }
  }

  var modelID: String {
    switch self {
    case .soniox: "stt-rt-v5"
    case .meta: "muse-voice-transcribe-1.0"
    case .local: "nemotron-3.5-asr-0.6b-560ms"
    }
  }

  var credentialKind: CredentialKind? {
    switch self {
    case .soniox: .soniox
    case .meta: .metaModelAPI
    case .local: nil
    }
  }

  var missingCredentialError: AppError {
    switch self {
    case .soniox: .missingSonioxKey
    case .meta: .missingMetaModelAPIKey
    case .local: .provider("Download the Local model in Dictation settings.")
    }
  }

  var connectedBufferLimitBytes: Int {
    switch self {
    case .soniox: 512_000
    case .meta: 160_000
    case .local: 160_000
    }
  }
}

enum LocalTranscriptionModel: String, CaseIterable, Codable, Identifiable, Sendable {
  case nemotron
  case apple

  var id: Self { self }
  var title: String {
    switch self {
    case .nemotron: "NVIDIA Nemotron — Recommended"
    case .apple: "Apple Speech"
    }
  }

  var setupDescription: String {
    switch self {
    case .apple:
      "Apple Speech transcribes on this Mac. Apple may need to download support for your chosen language. No NVIDIA weights or transcription account are needed."
    case .nemotron:
      "NVIDIA Nemotron is the recommended local model for English. It needs a 611 MB download and transcribes on this Mac without a transcription account."
    }
  }
}

struct TranscriptionConfiguration: Equatable, Sendable {
  let provider: TranscriptionProvider
  var localModel: LocalTranscriptionModel = .nemotron
  var appleLocaleIdentifier: String = ""

  var modelID: String {
    provider == .local && localModel == .apple ? "apple-speech-transcriber" : provider.modelID
  }
  var audioEncoding: String { "pcm_s16le_16000" }
  var zeroDataRetentionRequired: Bool? { provider == .meta ? true : nil }
}

struct TranscriptAssembler: Sendable {
  private(set) var confirmed = ""

  mutating func consume(_ tokens: [(text: String, isFinal: Bool)]) -> TranscriptSnapshot {
    var provisional = ""
    for token in tokens where token.text != "<fin>" {
      if token.isFinal { confirmed += token.text } else { provisional += token.text }
    }
    return TranscriptSnapshot(confirmed: confirmed, provisional: provisional)
  }
}

enum TranscriptTail {
  static func make(from snapshot: TranscriptSnapshot, limit: Int = 260) -> TranscriptSnapshot {
    let provisional = String(snapshot.provisional.suffix(limit))
    let remaining = max(0, limit - provisional.count)
    return TranscriptSnapshot(
      confirmed: String(snapshot.confirmed.suffix(remaining)), provisional: provisional)
  }
}

enum CleanupMode: String, CaseIterable, Codable, Sendable {
  case faithful = "Faithful"
  case polished = "Polished"
  case compose = "Compose"
  case custom = "Custom"

  var displayName: String {
    self == .compose || self == .custom ? "\(rawValue) (Experimental)" : rawValue
  }

  var summary: String {
    switch self {
    case .faithful: "Light cleanup that stays close to your wording."
    case .polished: "Improves grammar and flow while preserving your meaning."
    case .compose: "Formats lists and paragraphs and applies spoken corrections."
    case .custom: "Polished cleanup with your own tone, language, and formatting instructions."
    }
  }
}

/// Instructions are captured at recording start, independently of provider settings.
struct CleanupInstructions: Equatable, Sendable {
  static let maxCustomInstructionCharacters = 2_000

  let mode: CleanupMode
  let customInstructions: String

  var allowsExpansion: Bool {
    mode == .compose || !customInstructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  init(mode: CleanupMode, customInstructions: String = "") {
    self.mode = mode
    self.customInstructions = mode == .custom ? customInstructions : ""
  }

  func validate() throws {
    guard customInstructions.unicodeScalars.count <= Self.maxCustomInstructionCharacters else {
      throw AppError.provider("Custom instructions must be 2,000 characters or fewer.")
    }
  }
}

struct CleanupReasoningEffort: RawRepresentable, Hashable, CaseIterable, Codable, Sendable {
  let rawValue: String

  static let automatic = Self("automatic")
  static let none = Self("none")
  static let minimal = Self("minimal")
  static let low = Self("low")
  static let medium = Self("medium")
  static let high = Self("high")
  static let xhigh = Self("xhigh")
  static let max = Self("max")

  static let allCases: [Self] = [.automatic, .none, .minimal, .low, .medium, .high, .xhigh, .max]
  static let gatewayLevels: [Self] = [.none, .minimal, .low, .medium, .high, .xhigh, .max]

  private init(_ value: String) { rawValue = value }

  init?(rawValue: String) {
    guard rawValue.range(of: #"^[a-z][a-z0-9_-]{0,63}\z"#, options: .regularExpression) != nil
    else { return nil }
    self.rawValue = rawValue
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    let value = try container.decode(String.self)
    guard let effort = Self(rawValue: value) else {
      throw DecodingError.dataCorruptedError(
        in: container, debugDescription: "Invalid reasoning effort")
    }
    self = effort
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }

  var displayName: String {
    switch self {
    case .automatic: "Model default"
    case .none: "None"
    case .minimal: "Minimal"
    case .low: "Low"
    case .medium: "Medium"
    case .high: "High"
    case .xhigh: "Extra High"
    case .max: "Max"
    default: rawValue.replacingOccurrences(of: "_", with: " ").capitalized
    }
  }
}

enum CleanupProvider: String, CaseIterable, Codable, Sendable {
  case openRouter
  case groq
  case cerebras

  var displayName: String {
    switch self {
    case .openRouter: "OpenRouter"
    case .groq: "Groq"
    case .cerebras: "Cerebras"
    }
  }

  var isExperimental: Bool { self == .groq }

  var credentialKind: CredentialKind {
    switch self {
    case .openRouter: .openRouter
    case .groq: .groq
    case .cerebras: .cerebras
    }
  }

  var models: [CleanupModel] {
    CleanupModel.allCases.filter { $0.provider == self }
  }

  var defaultModel: CleanupModel {
    switch self {
    case .openRouter: .gemini35FlashLite
    case .groq: .qwen38_27BGroq
    case .cerebras: .qwen38_27BCerebras
    }
  }

  var missingCredentialError: AppError {
    switch self {
    case .openRouter: .missingOpenRouterKey
    case .groq: .missingGroqKey
    case .cerebras: .missingCerebrasKey
    }
  }
}

struct CleanupProviderRoute: Equatable, Sendable {
  let only: [String]?
  let sort: String?
  let requiresZeroDataRetention: Bool
  let allowsFallbacks: Bool

  var requestedProviderTag: String? { only?.first }
}

struct CleanupModel: Hashable, CaseIterable, Codable, Sendable {
  let rawValue: String
  let provider: CleanupProvider

  static let gemini37Flash = Self("google/gemini-3.7-flash")
  static let gptOSS120BCerebras = Self("openai/gpt-oss-120b")
  static let gemini35FlashLite = Self("google/gemini-3.5-flash-lite")
  static let gpt56LunaFast = Self("openai/gpt-5.6-luna")
  static let qwen38_27BGroq = Self("qwen/qwen3.8-27b", provider: .groq)
  static let qwen38_27BCerebras = Self("qwen-3.8-27b", provider: .cerebras)

  // These presets retain their existing routing and reasoning settings.
  static let allCases: [Self] = [
    .gemini37Flash, .gptOSS120BCerebras, .gemini35FlashLite, .gpt56LunaFast,
    .qwen38_27BGroq, .qwen38_27BCerebras,
  ]

  private init(_ rawValue: String, provider: CleanupProvider = .openRouter) {
    self.rawValue = rawValue
    self.provider = provider
  }

  init?(openRouterID: String) {
    let id = openRouterID.lowercased()
    let excludedFamilies = ["llama-guard", "gpt-oss-safeguard", "shieldgemma"]
    guard Self(rawValue: openRouterID) != nil, openRouterID.contains("/"),
      !id.hasPrefix("openrouter/"),
      !excludedFamilies.contains(where: { id.contains($0) })
    else { return nil }
    self.init(openRouterID)
  }

  static func saved(_ rawValue: String, for provider: CleanupProvider) -> Self? {
    let model = provider == .openRouter ? Self(openRouterID: rawValue) : Self(rawValue: rawValue)
    return model?.provider == provider ? model : nil
  }

  init?(rawValue: String) {
    if let preset = Self.allCases.first(where: { $0.rawValue == rawValue }) {
      self = preset
      return
    }
    // OpenRouter model IDs contain an author and a model, with optional variant suffixes.
    guard rawValue.count <= 200,
      rawValue.range(
        of: #"^~?[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9][A-Za-z0-9._:/-]*\z"#,
        options: .regularExpression) != nil
    else { return nil }
    self.init(rawValue)
  }

  private enum CodingKeys: String, CodingKey { case rawValue, provider }

  init(from decoder: Decoder) throws {
    if let value = try? decoder.singleValueContainer().decode(String.self),
      let model = Self(rawValue: value)
    {
      self = model
      return
    }
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let value = try container.decode(String.self, forKey: .rawValue)
    let provider = try container.decode(CleanupProvider.self, forKey: .provider)
    guard let model = Self.saved(value, for: provider) else {
      throw DecodingError.dataCorruptedError(
        forKey: .rawValue, in: container, debugDescription: "Invalid cleanup model ID")
    }
    self = model
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(rawValue, forKey: .rawValue)
    try container.encode(provider, forKey: .provider)
  }

  var isOpenRouterCatalogModel: Bool { !Self.allCases.contains(self) }

  static let defaultModel: CleanupModel = .gemini35FlashLite

  var displayName: String {
    switch self {
    case .gemini37Flash: "Gemini 3.7 Flash"
    case .gptOSS120BCerebras: "GPT-OSS 120B · Cerebras"
    case .gemini35FlashLite: "Gemini 3.5 Flash Lite"
    case .gpt56LunaFast: "GPT-5.6 Luna · Fast"
    case .qwen38_27BGroq: "Qwen 3.8 27B"
    case .qwen38_27BCerebras: "Qwen 3.8 27B"
    default: rawValue
    }
  }

  var supportedReasoningEfforts: [CleanupReasoningEffort] {
    switch self {
    case .gemini37Flash, .gptOSS120BCerebras:
      [.low, .medium, .high]
    case .gemini35FlashLite:
      [.minimal, .low, .medium, .high]
    case .gpt56LunaFast:
      [.none, .low, .medium, .high, .xhigh, .max]
    case .qwen38_27BGroq:
      [.none, .low]
    case .qwen38_27BCerebras:
      [.none, .low, .medium, .high]
    default:
      [.automatic]
    }
  }

  var defaultReasoningEffort: CleanupReasoningEffort {
    switch self {
    case .gemini35FlashLite: .minimal
    case .qwen38_27BGroq, .qwen38_27BCerebras: .none
    case .gemini37Flash, .gptOSS120BCerebras, .gpt56LunaFast: .low
    default: .automatic
    }
  }

  var providerRoute: CleanupProviderRoute {
    switch self {
    case .gemini37Flash, .gemini35FlashLite:
      CleanupProviderRoute(
        only: nil, sort: "latency", requiresZeroDataRetention: true,
        allowsFallbacks: true)
    case .gptOSS120BCerebras:
      CleanupProviderRoute(
        only: ["cerebras/fp16"], sort: nil, requiresZeroDataRetention: true,
        allowsFallbacks: false)
    case .gpt56LunaFast:
      CleanupProviderRoute(
        only: ["openai/fast"], sort: nil, requiresZeroDataRetention: false,
        allowsFallbacks: false)
    case .qwen38_27BGroq, .qwen38_27BCerebras:
      CleanupProviderRoute(
        only: nil, sort: nil, requiresZeroDataRetention: false,
        allowsFallbacks: false)
    default:
      CleanupProviderRoute(
        only: nil, sort: "latency", requiresZeroDataRetention: true, allowsFallbacks: true)
    }
  }

  func normalizedReasoningEffort(
    _ effort: CleanupReasoningEffort?, supportedEfforts: [CleanupReasoningEffort]? = nil
  ) -> CleanupReasoningEffort {
    if effort == .automatic && provider == .openRouter { return .automatic }
    let available = supportedEfforts ?? supportedReasoningEfforts
    if let effort, available.contains(effort) { return effort }
    if available.contains(defaultReasoningEffort) { return defaultReasoningEffort }
    return .automatic
  }

}

struct CleanupConfiguration: Equatable, Sendable {
  let model: CleanupModel
  let reasoningEffort: CleanupReasoningEffort
  let catalogRequiresZeroDataRetention: Bool

  var provider: CleanupProvider { model.provider }

  var providerRoute: CleanupProviderRoute {
    let route = model.providerRoute
    guard model.isOpenRouterCatalogModel else { return route }
    return CleanupProviderRoute(
      only: route.only, sort: route.sort,
      requiresZeroDataRetention: catalogRequiresZeroDataRetention,
      allowsFallbacks: route.allowsFallbacks)
  }

  init(
    model: CleanupModel, reasoningEffort: CleanupReasoningEffort,
    catalogRequiresZeroDataRetention: Bool = true,
    supportedReasoningEfforts: [CleanupReasoningEffort]? = nil
  ) {
    self.catalogRequiresZeroDataRetention = catalogRequiresZeroDataRetention
    self.model = model
    self.reasoningEffort = model.normalizedReasoningEffort(
      reasoningEffort, supportedEfforts: supportedReasoningEfforts)
  }
}

struct NotchGeometry: Equatable, Sendable {
  static let physicalNotchReferenceWidth: CGFloat = 220
  static let contentBandHeight: CGFloat = 34
  static let externalFallbackHeight: CGFloat = 44

  let frame: CGRect
  let physicalNotchWidth: CGFloat
  let physicalNotchHeight: CGFloat
  let isExternalFallback: Bool

  static func calculate(for screen: NSScreen) -> NotchGeometry {
    calculate(
      frame: screen.frame, safeAreaTop: screen.safeAreaInsets.top,
      auxiliaryLeft: screen.auxiliaryTopLeftArea, auxiliaryRight: screen.auxiliaryTopRightArea)
  }

  static func calculate(
    frame visible: CGRect, safeAreaTop physicalHeight: CGFloat, auxiliaryLeft left: CGRect?,
    auxiliaryRight right: CGRect?
  ) -> NotchGeometry {
    let physicalWidth: CGFloat
    if physicalHeight > 0, let left, let right {
      physicalWidth = max(0, right.minX - left.maxX)
    } else {
      physicalWidth = 0
    }
    let fallback = physicalHeight <= 0 || physicalWidth <= 0
    let width = max(360, physicalWidth + 140)
    let height = fallback ? externalFallbackHeight : physicalHeight + contentBandHeight
    return NotchGeometry(
      frame: CGRect(
        x: visible.midX - width / 2, y: visible.maxY - height, width: width, height: height),
      physicalNotchWidth: physicalWidth,
      physicalNotchHeight: physicalHeight,
      isExternalFallback: fallback
    )
  }
}

enum VocabularyNormalizer {
  enum Addition: Equatable {
    case added([String])
    case empty
    case duplicate
    case multipleTerms
    case limitExceeded
  }

  static func parse(_ raw: String) -> [String] {
    var seen = Set<String>()
    var result: [String] = []
    for line in raw.components(separatedBy: .newlines) {
      let term = line.trimmingCharacters(in: .whitespacesAndNewlines)
      let key = term.lowercased()
      guard !term.isEmpty, !seen.contains(key) else { continue }
      seen.insert(key)
      result.append(term)
    }
    return result
  }

  static func normalize(_ raw: String, limit: Int = 10_000) -> [String] {
    var total = 0
    var result: [String] = []
    for term in parse(raw) {
      let added = term.utf8.count + (result.isEmpty ? 0 : 1)
      guard total + added <= limit else { break }
      result.append(term)
      total += added
    }
    return result
  }

  static func adding(_ candidate: String, to raw: String, limit: Int = 10_000) -> Addition {
    let term = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !term.isEmpty else { return .empty }
    guard term.rangeOfCharacter(from: .newlines) == nil else { return .multipleTerms }

    let terms = parse(raw)
    guard !terms.contains(where: { $0.caseInsensitiveCompare(term) == .orderedSame }) else {
      return .duplicate
    }

    let updated = terms + [term]
    guard updated.joined(separator: "\n").utf8.count <= limit else { return .limitExceeded }
    return .added(updated)
  }

  static func removing(_ term: String, from raw: String) -> [String] {
    parse(raw).filter {
      $0.caseInsensitiveCompare(term) != .orderedSame
    }
  }
}

protocol AudioCapturing: AnyObject, Sendable {
  var onAudio: ((Data) -> Void)? { get set }
  func prepare() async
  func prepareWithDiagnostics() async -> DiagnosticPreparationResult
  func discardPreparation()
  /// Returns whether launch-time preparation was reused.
  func start() async throws -> Bool
  func cancelStart()
  func stop()
}

extension AudioCapturing {
  func prepareWithDiagnostics() async -> DiagnosticPreparationResult {
    await prepare()
    return Task.isCancelled ? .cancelled : .unknown
  }
}

@MainActor
protocol RealtimeTranscribing: AnyObject {
  var onTranscript: ((RealtimeTranscriptUpdate) -> Void)? { get set }
  var onError: ((Error) -> Void)? { get set }
  func connect(
    configuration: TranscriptionConfiguration, apiKey: String, vocabulary: [String],
    sessionID: DictationSessionID
  ) async throws
  func send(_ frame: RealtimeAudioFrame) async throws
  func finish() async throws -> String
  func cancel()
}

protocol CleaningText: Sendable {
  func warmUp(configuration: CleanupConfiguration, apiKey: String) async
  func clean(
    _ text: String, instructions: CleanupInstructions, configuration: CleanupConfiguration, apiKey: String
  ) async throws -> CleanupTextResult
}

extension CleaningText {
  func clean(
    _ text: String, mode: CleanupMode, configuration: CleanupConfiguration, apiKey: String
  ) async throws -> CleanupTextResult {
    try await clean(text, instructions: CleanupInstructions(mode: mode),
                    configuration: configuration, apiKey: apiKey)
  }

  func warmUp(configuration: CleanupConfiguration, apiKey: String) async {}
}

struct CleanupTextResult: Equatable, Sendable {
  let text: String
  let metrics: CleanupRequestMetrics
}

struct CleanupProviderTimingMetrics: Codable, Equatable, Sendable {
  let queueMS: Double?
  let promptMS: Double?
  let completionMS: Double?
  let totalMS: Double?
}

struct CleanupNetworkTimingMetrics: Codable, Equatable, Sendable {
  let connectionReused: Bool?
  let networkProtocolName: String?
  let dnsMS: Double?
  let connectMS: Double?
  let secureConnectionMS: Double?
  let requestUploadMS: Double?
  let timeToFirstByteMS: Double?
  let responseDownloadMS: Double?
}

struct CleanupRequestMetrics: Equatable, Sendable {
  let actualModel: String?
  let selectedProvider: String?
  let selectedProviderModel: String?
  let routingStrategy: String?
  let routingAttempt: Int?
  let serviceTier: String?
  let promptTokens: Int?
  let completionTokens: Int?
  let totalTokens: Int?
  let httpStatus: Int?
  let cachedPromptTokens: Int?
  let requestEncodingMS: Double?
  let networkRequestMS: Double?
  let responseDecodingMS: Double?
  let providerTiming: CleanupProviderTimingMetrics?
  let networkTiming: CleanupNetworkTimingMetrics?

  init(
    actualModel: String?, selectedProvider: String?, selectedProviderModel: String?,
    routingStrategy: String?, routingAttempt: Int?, serviceTier: String?, promptTokens: Int?,
    completionTokens: Int?, totalTokens: Int?, httpStatus: Int?, cachedPromptTokens: Int? = nil,
    requestEncodingMS: Double? = nil, networkRequestMS: Double? = nil,
    responseDecodingMS: Double? = nil, providerTiming: CleanupProviderTimingMetrics? = nil,
    networkTiming: CleanupNetworkTimingMetrics? = nil
  ) {
    self.actualModel = actualModel
    self.selectedProvider = selectedProvider
    self.selectedProviderModel = selectedProviderModel
    self.routingStrategy = routingStrategy
    self.routingAttempt = routingAttempt
    self.serviceTier = serviceTier
    self.promptTokens = promptTokens
    self.completionTokens = completionTokens
    self.totalTokens = totalTokens
    self.httpStatus = httpStatus
    self.cachedPromptTokens = cachedPromptTokens
    self.requestEncodingMS = requestEncodingMS
    self.networkRequestMS = networkRequestMS
    self.responseDecodingMS = responseDecodingMS
    self.providerTiming = providerTiming
    self.networkTiming = networkTiming
  }
}

struct ProviderHTTPError: LocalizedError, Sendable {
  let statusCode: Int
  let message: String
  let cleanupMetrics: CleanupRequestMetrics?

  init(statusCode: Int, message: String, cleanupMetrics: CleanupRequestMetrics? = nil) {
    self.statusCode = statusCode
    self.message = message
    self.cleanupMetrics = cleanupMetrics
  }

  var errorDescription: String? { message }
}

struct CleanupNetworkError: LocalizedError, Sendable {
  let code: URLError.Code
  let cleanupMetrics: CleanupRequestMetrics

  var errorDescription: String? { URLError(code).localizedDescription }
}

protocol OutputMuting: AnyObject {
  func mute() -> Bool
  func restore()
}

@MainActor
protocol TextInserting: Sendable {
  /// Begins acquisition immediately at stop; callers cancel this task with the session.
  func captureTarget() -> Task<TextInsertionTarget?, Never>
  func insert(_ text: String, into target: TextInsertionTarget?) async -> InsertionResult
  func invalidatePendingRestoration()
}

extension TextInserting {
  func invalidatePendingRestoration() {}
}

enum InsertionResult: Equatable, Sendable {
  case pasteSent
  case copied(PasteBlockReason)
  case failed(String)
  case cancelled
}

enum PasteBlockReason: String, Error, Equatable, Sendable, CaseIterable {
  case secureField, secureInput, readOnlyTarget, unsupportedField, targetUnavailable
  case targetChanged, accessibilityPermission, modifiersHeld, shortcutUnavailable, clipboardChanged

  var copiedMessage: String {
    switch self {
    case .secureField: "Secure field—copied instead. Paste manually if intended."
    case .secureInput: "Secure keyboard input—copied instead. Paste manually if intended."
    case .readOnlyTarget: "Read-only field—copied instead."
    case .unsupportedField: "No supported text field—copied instead."
    case .targetUnavailable: "Couldn’t verify the original field—copied instead."
    case .targetChanged: "App or field changed—copied instead."
    case .accessibilityPermission: "Accessibility permission needed—copied instead."
    case .modifiersHeld: "Shortcut keys still held—copied instead."
    case .shortcutUnavailable: "Couldn’t send Paste—copied instead."
    case .clipboardChanged: "Clipboard changed—paste skipped."
    }
  }
}

@MainActor
protocol NotchPresenting: AnyObject {
  func present(state: NotchState)
  func hide(after delay: Duration)
}

struct NotchState: Equatable, Sendable {
  var phase: DictationPhase
  var transcript = TranscriptSnapshot()
  var warning: String?
}

enum AppError: LocalizedError {
  case missingSonioxKey
  case missingMetaModelAPIKey
  case missingOpenRouterKey
  case missingGroqKey
  case missingCerebrasKey
  case microphoneUnavailable
  case connectionTimeout
  case finalizeTimeout
  case emptyTranscript
  case provider(String)

  var errorDescription: String? {
    switch self {
    case .missingSonioxKey: "Add and verify a Soniox API key in Settings."
    case .missingMetaModelAPIKey: "Add and verify a Meta Model API key in Settings."
    case .missingOpenRouterKey: "Add and verify an OpenRouter API key in Settings."
    case .missingGroqKey: "Add and verify a Groq API key in Settings."
    case .missingCerebrasKey: "Add and verify a Cerebras API key in Settings."
    case .microphoneUnavailable: "Microphone access is required."
    case .connectionTimeout: "The transcription provider did not connect in time."
    case .finalizeTimeout: "The transcription provider did not finish in time."
    case .emptyTranscript: "No speech detected."
    case .provider(let message): message
    }
  }
}

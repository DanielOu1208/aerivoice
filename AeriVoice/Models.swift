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

  var id: Self { self }

  var displayName: String {
    switch self {
    case .soniox: "Soniox"
    case .meta: "Meta"
    }
  }

  var modelDisplayName: String {
    switch self {
    case .soniox: "Soniox Realtime"
    case .meta: "Muse Voice Transcribe 1.0"
    }
  }

  var modelID: String {
    switch self {
    case .soniox: "stt-rt-v5"
    case .meta: "muse-voice-transcribe-1.0"
    }
  }

  var credentialKind: CredentialKind {
    switch self {
    case .soniox: .soniox
    case .meta: .metaModelAPI
    }
  }

  var missingCredentialError: AppError {
    switch self {
    case .soniox: .missingSonioxKey
    case .meta: .missingMetaModelAPIKey
    }
  }

  var connectedBufferLimitBytes: Int {
    switch self {
    case .soniox: 512_000
    case .meta: 160_000
    }
  }
}

struct TranscriptionConfiguration: Equatable, Sendable {
  let provider: TranscriptionProvider

  var modelID: String { provider.modelID }
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
}

enum CleanupReasoningEffort: String, CaseIterable, Codable, Sendable {
  case none
  case minimal
  case low
  case medium
  case high
  case xhigh
  case max

  var displayName: String {
    switch self {
    case .none: "None"
    case .minimal: "Minimal"
    case .low: "Low"
    case .medium: "Medium"
    case .high: "High"
    case .xhigh: "Extra High"
    case .max: "Max"
    }
  }
}

enum CleanupProvider: String, CaseIterable, Codable, Sendable {
  case openRouter
  case groq

  var displayName: String {
    switch self {
    case .openRouter: "OpenRouter"
    case .groq: "Groq"
    }
  }

  var isExperimental: Bool { self == .groq }

  var credentialKind: CredentialKind {
    switch self {
    case .openRouter: .openRouter
    case .groq: .groq
    }
  }

  var models: [CleanupModel] {
    CleanupModel.allCases.filter { $0.provider == self }
  }

  var defaultModel: CleanupModel {
    switch self {
    case .openRouter: .gemini35FlashLite
    case .groq: .qwen38_27BGroq
    }
  }

  var missingCredentialError: AppError {
    switch self {
    case .openRouter: .missingOpenRouterKey
    case .groq: .missingGroqKey
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

enum CleanupModel: String, CaseIterable, Codable, Sendable {
  case gemini37Flash = "google/gemini-3.7-flash"
  case gptOSS120BCerebras = "openai/gpt-oss-120b"
  case gemini35FlashLite = "google/gemini-3.5-flash-lite"
  case gpt56LunaFast = "openai/gpt-5.6-luna"
  case qwen38_27BGroq = "qwen/qwen3.8-27b"

  static let defaultModel: CleanupModel = .gemini35FlashLite

  var displayName: String {
    switch self {
    case .gemini37Flash: "Gemini 3.7 Flash"
    case .gptOSS120BCerebras: "GPT-OSS 120B · Cerebras"
    case .gemini35FlashLite: "Gemini 3.5 Flash Lite"
    case .gpt56LunaFast: "GPT-5.6 Luna · Fast"
    case .qwen38_27BGroq: "Qwen 3.8 27B"
    }
  }

  var provider: CleanupProvider {
    switch self {
    case .gemini37Flash, .gptOSS120BCerebras, .gemini35FlashLite, .gpt56LunaFast:
      .openRouter
    case .qwen38_27BGroq:
      .groq
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
    }
  }

  var defaultReasoningEffort: CleanupReasoningEffort {
    switch self {
    case .gemini35FlashLite: .minimal
    case .qwen38_27BGroq: .none
    default: .low
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
    case .qwen38_27BGroq:
      CleanupProviderRoute(
        only: nil, sort: nil, requiresZeroDataRetention: false,
        allowsFallbacks: false)
    }
  }

  func normalizedReasoningEffort(_ effort: CleanupReasoningEffort?) -> CleanupReasoningEffort {
    guard let effort, supportedReasoningEfforts.contains(effort) else {
      return defaultReasoningEffort
    }
    return effort
  }
}

struct CleanupConfiguration: Equatable, Sendable {
  let model: CleanupModel
  let reasoningEffort: CleanupReasoningEffort

  var provider: CleanupProvider { model.provider }

  init(model: CleanupModel, reasoningEffort: CleanupReasoningEffort) {
    self.model = model
    self.reasoningEffort = model.normalizedReasoningEffort(reasoningEffort)
  }
}

enum ShortcutActivationMode: String, CaseIterable, Equatable, Identifiable, Sendable {
  case toggle
  case hybrid

  var id: Self { self }

  var title: String {
    switch self {
    case .toggle: "Toggle"
    case .hybrid: "Hybrid"
    }
  }

  var instructions: String {
    switch self {
    case .toggle:
      "Press the shortcut once to start dictation and again to finish."
    case .hybrid:
      "Tap once to start and again to finish, or hold the shortcut and release to finish."
    }
  }
}

struct ShortcutDefinition: Codable, Equatable, Sendable {
  let keyCode: UInt16
  let modifiers: UInt
  let displayName: String
  let isModifierOnly: Bool

  init(keyCode: UInt16, modifiers: UInt, displayName: String, isModifierOnly: Bool = false) {
    self.keyCode = keyCode
    self.modifiers = modifiers
    self.displayName = displayName
    self.isModifierOnly = isModifierOnly
  }

  private enum CodingKeys: String, CodingKey {
    case keyCode, modifiers, displayName, isModifierOnly
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    keyCode = try container.decode(UInt16.self, forKey: .keyCode)
    modifiers = try container.decode(UInt.self, forKey: .modifiers)
    displayName = try container.decode(String.self, forKey: .displayName)
    isModifierOnly = try container.decodeIfPresent(Bool.self, forKey: .isModifierOnly) ?? false
  }

  var cgFlags: CGEventFlags { CGEventFlags(rawValue: UInt64(modifiers)) }
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

protocol AudioCapturing: AnyObject {
  var onAudio: ((Data) -> Void)? { get set }
  func start() throws
  func stop()
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
  func clean(
    _ text: String, mode: CleanupMode, configuration: CleanupConfiguration, apiKey: String
  ) async throws -> CleanupTextResult
}

struct CleanupTextResult: Equatable, Sendable {
  let text: String
  let metrics: CleanupRequestMetrics
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
  let httpStatus: Int
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

protocol OutputMuting: AnyObject {
  func mute() -> Bool
  func restore()
}

@MainActor
protocol TextInserting: Sendable {
  func insert(_ text: String) async -> InsertionResult
}

enum InsertionResult: Equatable, Sendable {
  case inserted
  case copied(String)
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
    case .microphoneUnavailable: "Microphone access is required."
    case .connectionTimeout: "The transcription provider did not connect in time."
    case .finalizeTimeout: "The transcription provider did not finish in time."
    case .emptyTranscript: "No speech detected."
    case .provider(let message): message
    }
  }
}

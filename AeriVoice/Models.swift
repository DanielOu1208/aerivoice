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
  static func normalize(_ raw: String, limit: Int = 10_000) -> [String] {
    var seen = Set<String>()
    var total = 0
    var result: [String] = []
    for line in raw.components(separatedBy: .newlines) {
      let term = line.trimmingCharacters(in: .whitespacesAndNewlines)
      let key = term.lowercased()
      guard !term.isEmpty, !seen.contains(key) else { continue }
      let added = term.utf8.count + (result.isEmpty ? 0 : 1)
      guard total + added <= limit else { break }
      seen.insert(key)
      result.append(term)
      total += added
    }
    return result
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
  func connect(apiKey: String, vocabulary: [String], sessionID: DictationSessionID) async throws
  func send(_ audio: Data) async throws
  func finish() async throws -> String
  func cancel()
}

protocol CleaningText: Sendable {
  func clean(_ text: String, mode: CleanupMode, apiKey: String) async throws -> CleanupTextResult
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
  case missingOpenRouterKey
  case microphoneUnavailable
  case connectionTimeout
  case finalizeTimeout
  case emptyTranscript
  case provider(String)

  var errorDescription: String? {
    switch self {
    case .missingSonioxKey: "Add and verify a Soniox API key in Settings."
    case .missingOpenRouterKey: "Add and verify an OpenRouter API key in Settings."
    case .microphoneUnavailable: "Microphone access is required."
    case .connectionTimeout: "Soniox did not connect in time."
    case .finalizeTimeout: "Soniox did not finish in time."
    case .emptyTranscript: "No speech detected."
    case .provider(let message): message
    }
  }
}

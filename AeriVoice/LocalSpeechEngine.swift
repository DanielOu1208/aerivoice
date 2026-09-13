import Foundation
import FluidAudio

protocol LocalSpeechEngine: Sendable {
  func load(from directory: URL) async throws
  func reset() async
  func setVocabulary(_ words: [String]) async
  func process(_ samples: [Float]) async throws -> String
  func finish() async throws -> String
}

actor FluidLocalSpeechEngine: LocalSpeechEngine {
  private let manager = StreamingNemotronMultilingualAsrManager()
  func load(from directory: URL) async throws {
    try await manager.loadModels(from: directory)
    await manager.setLanguage("en-US")
  }
  func reset() async { await manager.reset() }
  func setVocabulary(_ words: [String]) async {
    await manager.setCustomVocabulary(words.map { CustomVocabularyTerm(text: $0) })
  }
  func process(_ samples: [Float]) async throws -> String {
    _ = try await manager.process(samples: samples)
    return await manager.getPartialTranscript()
  }
  func finish() async throws -> String { try await manager.finish() }
}

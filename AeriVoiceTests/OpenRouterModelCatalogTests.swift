import XCTest

@testable import AeriVoice

final class OpenRouterModelCatalogTests: XCTestCase {
  func testCatalogFiltersNonCleanupModelsAndDeduplicates() throws {
    let data = #"""
      {"data":[
        {"id":"vendor/chat","name":"Chat","architecture":{"input_modalities":["text"],"output_modalities":["text"]}},
        {"id":"vendor/vision","name":"Vision","architecture":{"input_modalities":["text","image"],"output_modalities":["text"]}},
        {"id":"vendor/image","name":"Image","architecture":{"input_modalities":["text"],"output_modalities":["text","image"]}},
        {"id":"vendor/speech","name":"Speech","architecture":{"input_modalities":["audio"],"output_modalities":["text"]}},
        {"id":"vendor/embedding","name":"Embedding","architecture":{"input_modalities":["text"],"output_modalities":["embeddings"]}},
        {"id":"vendor/video","name":"Video","architecture":{"input_modalities":["text"],"output_modalities":["video"]}},
        {"id":"openrouter/auto","name":"Auto","architecture":{"input_modalities":["text"],"output_modalities":["text"]}},
        {"id":"vendor/chat","name":"Duplicate","architecture":{"input_modalities":["text"],"output_modalities":["text"]}},
        {"id":"not-a-model","name":"Invalid","architecture":{"input_modalities":["text"],"output_modalities":["text"]}}
      ]}
      """#.data(using: .utf8)!
    let models = try OpenRouterModelCatalog.decode(data)
    XCTAssertEqual(models.map(\.id), ["vendor/chat", "vendor/vision"])
    XCTAssertTrue(models[0].matches(" CHAT "))
    XCTAssertTrue(models[0].matches("vendor/"))
    XCTAssertFalse(models[0].matches("missing"))
  }

  func testCustomModelsRejectMalformedIDsAndPreserveProviderInCodable() throws {
    for invalid in [
      "", "removed-model", "vendor/", "vendor/model\n", "https://example.com/model",
      "vendor/model key", "openrouter/auto", "openai/gpt-oss-safeguard-20b",
      "meta-llama/llama-guard-4-12b",
    ] {
      XCTAssertNil(CleanupModel(openRouterID: invalid), invalid)
    }
    let model = try XCTUnwrap(CleanupModel(openRouterID: "qwen/qwen3.8-27b"))
    XCTAssertEqual(model.provider, .openRouter)
    XCTAssertNotEqual(model, .qwen38_27BGroq)
    XCTAssertEqual(model.defaultReasoningEffort, .automatic)
    XCTAssertEqual(
      try JSONDecoder().decode(CleanupModel.self, from: JSONEncoder().encode(model)), model)
    let legacy = Data(#""qwen/qwen3.8-27b""#.utf8)
    XCTAssertEqual(try JSONDecoder().decode(CleanupModel.self, from: legacy), .qwen38_27BGroq)
  }

  @MainActor
  func testCustomSelectionSurvivesRelaunchAndProviderSwitchingWithoutCatalog() throws {
    let suite = "AeriVoiceTests.OpenRouterCatalog.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let preferences = AppPreferences(defaults: defaults)
    XCTAssertTrue(preferences.catalogRequiresZeroDataRetention)
    let model = try XCTUnwrap(CleanupModel(openRouterID: "qwen/qwen3.8-27b"))
    preferences.cleanupModel = model
    preferences.cleanupReasoningEffort = .high
    XCTAssertEqual(preferences.cleanupReasoningEffort, .automatic)
    let captured = preferences.cleanupConfiguration
    preferences.catalogRequiresZeroDataRetention = false
    XCTAssertTrue(captured.catalogRequiresZeroDataRetention)
    XCTAssertFalse(preferences.cleanupConfiguration.catalogRequiresZeroDataRetention)

    let restored = AppPreferences(defaults: defaults)
    XCTAssertEqual(restored.cleanupProvider, .openRouter)
    XCTAssertEqual(restored.cleanupModel, model)
    XCTAssertFalse(restored.catalogRequiresZeroDataRetention)
    restored.cleanupProvider = .groq
    XCTAssertEqual(restored.cleanupModel, .qwen38_27BGroq)
    restored.cleanupReasoningEffort = .low
    restored.cleanupProvider = .openRouter
    XCTAssertEqual(restored.cleanupModel, model)
    XCTAssertEqual(restored.cleanupReasoningEffort, .automatic)
    XCTAssertEqual(restored.cleanupConfiguration(for: .groq).reasoningEffort, .low)
  }
}

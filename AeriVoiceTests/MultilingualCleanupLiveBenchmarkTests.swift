import Foundation
import XCTest

@testable import AeriVoice

final class MultilingualCleanupLiveBenchmarkTests: XCTestCase {
  private struct Configuration: Decodable {
    let credentialPipePath: String
    let outputPath: String
  }

  func testSyntheticChineseCleanup() async throws {
    let configurationURL = URL(fileURLWithPath: "/tmp/aerivoice-multilingual-benchmark.plist")
    guard let data = try? Data(contentsOf: configurationURL) else {
      throw XCTSkip("Requires an explicitly configured live multilingual benchmark.")
    }
    try FileManager.default.removeItem(at: configurationURL)
    let config = try PropertyListDecoder().decode(Configuration.self, from: data)
    let pipe = try FileHandle(forReadingFrom: URL(fileURLWithPath: config.credentialPipePath))
    defer { try? pipe.close() }
    let keyData = try pipe.readToEnd() ?? Data()
    let key = try XCTUnwrap(String(data: keyData, encoding: .utf8))
    guard !key.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
    let fixtures: [(id: String, text: String)] = [
      ("simplified", "嗯那个我我想说我们明天下午三点开会不对是四点请把预算改成两千五百元然后发给小王"),
      ("traditional", "嗯那個我我想說我們明天下午三點開會不對是四點請把預算改成兩千五百元然後發給小王"),
      ("mixed", "嗯我们明天review这个pull request然后把userID传给API不要改成user_id还有deadline是Friday下午三点")
    ]
    let outputURL = URL(fileURLWithPath: config.outputPath)
    XCTAssertTrue(FileManager.default.createFile(
      atPath: outputURL.path, contents: nil, attributes: [.posixPermissions: 0o600]))
    let output = try FileHandle(forWritingTo: outputURL)
    defer { try? output.close() }
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    let client = CerebrasCleanupClient(session: session)
    let configuration = CleanupConfiguration(model: .qwen38_27BCerebras, reasoningEffort: .none)
    for fixture in fixtures {
      for mode: CleanupMode in [.faithful, .polished] {
        let started = Date()
        let result = try await client.clean(
          fixture.text, mode: mode, configuration: configuration, apiKey: key)
        let record: [String: Any] = [
          "fixture": fixture.id, "mode": mode.rawValue,
          "input": fixture.text, "output": result.text,
          "elapsedMS": Date().timeIntervalSince(started) * 1_000,
          "model": result.metrics.actualModel ?? configuration.model.rawValue,
          "promptTokens": result.metrics.promptTokens ?? 0,
          "completionTokens": result.metrics.completionTokens ?? 0,
          "providerQueueMS": result.metrics.providerTiming?.queueMS ?? 0,
          "promptLanguage": "English", "review": "manual review required"
        ]
        var line = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        line.append(0x0A)
        try output.write(contentsOf: line)
        XCTAssertFalse(result.text.isEmpty)
      }
    }
  }
}

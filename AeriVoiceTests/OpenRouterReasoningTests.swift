import XCTest

@testable import AeriVoice

final class OpenRouterReasoningTests: XCTestCase {
  func testSpecificEffortsKeepFutureValuesAndRemoveMandatoryOff() throws {
    let reasoning = try decode(
      #"{"supported_efforts":["future_level","high","low","none","low"],"mandatory":true,"default_effort":"future_level","default_enabled":true,"supports_max_tokens":true}"#
    )
    let future = try XCTUnwrap(CleanupReasoningEffort(rawValue: "future_level"))
    XCTAssertEqual(reasoning.selectableEfforts, [.low, .high, future])
    XCTAssertEqual(reasoning.defaultEffort, future)
    XCTAssertEqual(future.displayName, "Future Level")
    XCTAssertEqual(reasoning.defaultEnabled, true)
    XCTAssertTrue(reasoning.supportsMaxTokens)
    XCTAssertEqual(
      try JSONDecoder().decode(OpenRouterReasoning.self, from: JSONEncoder().encode(reasoning)),
      reasoning)
  }

  func testNullMissingAndEmptyEffortsStayDistinctAfterCaching() throws {
    for json in [#"{"supported_efforts":null}"#, #"{}"#, #"{"supported_efforts":[]}"#] {
      let reasoning = try decode(json)
      let restored = try JSONDecoder().decode(
        OpenRouterReasoning.self, from: JSONEncoder().encode(reasoning))
      XCTAssertEqual(restored, reasoning)
    }
    XCTAssertEqual(
      try decode(#"{"supported_efforts":null}"#).selectableEfforts,
      CleanupReasoningEffort.gatewayLevels)
    XCTAssertEqual(
      try decode(#"{"supported_efforts":null,"mandatory":true}"#).selectableEfforts,
      CleanupReasoningEffort.gatewayLevels.filter { $0 != .none })
    XCTAssertEqual(try decode(#"{}"#).efforts, .unavailable)
    XCTAssertTrue(try decode(#"{}"#).selectableEfforts.isEmpty)
    XCTAssertEqual(try decode(#"{"supported_efforts":[]}"#).efforts, .specific([]))
  }

  func testEffortSerializationRemainsCompatibleWithLegacyStrings() throws {
    XCTAssertEqual(
      try JSONDecoder().decode(CleanupReasoningEffort.self, from: Data(#""high""#.utf8)), .high)
    let future = try XCTUnwrap(CleanupReasoningEffort(rawValue: "future_level"))
    XCTAssertEqual(try JSONEncoder().encode(future), Data(#""future_level""#.utf8))
    for invalid in ["", "high\n", "a b", "reasoning/level"] {
      XCTAssertNil(CleanupReasoningEffort(rawValue: invalid))
    }
    XCTAssertNotNil(CleanupModel(openRouterID: "~vendor/latest-model"))
  }

  private func decode(_ json: String) throws -> OpenRouterReasoning {
    try JSONDecoder().decode(OpenRouterReasoning.self, from: Data(json.utf8))
  }
}

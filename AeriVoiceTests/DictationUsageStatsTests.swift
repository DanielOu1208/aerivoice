import Foundation
import XCTest
@testable import AeriVoice

extension DictationCoordinatorTests {
  @MainActor final class UsageSpy: UsageStatsRecording {
    var active: Set<UsageSession> = []
    var completions: [(words: Int, seconds: Double)] = []
    func begin() -> UsageSession? {
      let session = UsageSession(generation: UUID())
      active.insert(session)
      return session
    }
    func complete(_ session: UsageSession, words: Int, recordingSeconds: Double, at date: Date) {
      guard active.remove(session) != nil else { return }
      completions.append((words, recordingSeconds))
    }
    func discard(_ session: UsageSession) { active.remove(session) }
  }

  func testUsageCountsFinalPastedOutputWithoutDiagnostics() async throws {
    let usage = UsageSpy()
    let fixture = makeFixture(usageStats: usage)
    fixture.preferences.latencyLogging = false
    fixture.coordinator.toggle()
    try await waitUntil { fixture.coordinator.phase == .recording }
    fixture.coordinator.toggle()
    try await waitUntil { fixture.coordinator.phase == .success }
    XCTAssertEqual(usage.completions.count, 1)
    XCTAssertEqual(usage.completions.first?.words, 2) // "Cleaned text."
    XCTAssertGreaterThan(usage.completions.first!.seconds, 0)
    XCTAssertTrue(usage.active.isEmpty)
    fixture.coordinator.cancel()
    XCTAssertEqual(usage.completions.count, 1)
  }

  func testUsageCountsCopiedOutputAndRawCleanupFallback() async throws {
    let usage = UsageSpy()
    let fixture = makeFixture(usageStats: usage, cleanupError: ProviderHTTPError(statusCode: 500, message: "test"))
    fixture.inserter.result = .copied(.targetChanged)
    fixture.coordinator.toggle()
    try await waitUntil { fixture.coordinator.phase == .recording }
    fixture.coordinator.toggle()
    try await waitUntil { !usage.completions.isEmpty }
    XCTAssertEqual(usage.completions.first?.words, 2) // "Raw transcript"
    XCTAssertTrue(usage.active.isEmpty)
    fixture.coordinator.cancel()
  }

  func testUsageExcludesCancellationAndInsertionFailure() async throws {
    let usage = UsageSpy()
    let fixture = makeFixture(usageStats: usage)
    fixture.coordinator.toggle()
    try await waitUntil { fixture.coordinator.phase == .recording }
    fixture.coordinator.cancel()
    XCTAssertTrue(usage.active.isEmpty)
    XCTAssertTrue(usage.completions.isEmpty)
    fixture.inserter.result = .failed("Test failure")
    fixture.coordinator.toggle()
    try await waitUntil { fixture.coordinator.phase == .recording }
    fixture.coordinator.toggle()
    try await waitUntil { fixture.coordinator.phase == .error("Test failure") }
    XCTAssertTrue(usage.active.isEmpty)
    XCTAssertTrue(usage.completions.isEmpty)
    fixture.coordinator.cancel()
  }
}

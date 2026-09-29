import XCTest
@testable import AeriVoice

@MainActor
final class GrokPreparationControllerTests: XCTestCase {
  private func settle() async { for _ in 0..<20 { await Task.yield() } }

  func testWakeWhileLockedCannotPrepareAndStopIsPermanent() async {
    var preparations = 0
    var discards = 0
    let policy = GrokPreparationController(initiallyLocked: true, eligible: { true },
      prepare: { preparations += 1; return true }, discard: { discards += 1 })
    policy.request()
    policy.setSleeping(true)
    policy.setSleeping(false)
    await settle()
    XCTAssertEqual(preparations, 0)
    policy.setLocked(false)
    await settle()
    XCTAssertEqual(preparations, 1)
    policy.setSleeping(true)
    policy.setLocked(false)
    await settle()
    XCTAssertEqual(preparations, 1)
    policy.setSleeping(false)
    await settle()
    XCTAssertEqual(preparations, 2)
    policy.stop()
    policy.setLocked(false)
    policy.request()
    await settle()
    XCTAssertEqual(preparations, 2)
    XCTAssertGreaterThan(discards, 0)
  }

  func testIneligibleConfigurationDiscardsWithoutStartingWork() async {
    var eligible = true
    var preparations = 0
    var discards = 0
    let policy = GrokPreparationController(initiallyLocked: false, eligible: { eligible },
      prepare: { preparations += 1; return true }, discard: { discards += 1 })
    policy.request()
    await settle()
    eligible = false
    policy.request()
    await settle()
    XCTAssertEqual(preparations, 1)
    XCTAssertEqual(discards, 1)
    policy.stop()
  }

  func testRepeatedRequestsAndLateCompletionCannotReplaceNewPreparation() async {
    var waits: [CheckedContinuation<Bool, Never>] = []
    let policy = GrokPreparationController(initiallyLocked: false, eligible: { true },
      prepare: { await withCheckedContinuation { waits.append($0) } }, discard: {})
    policy.request()
    await settle()
    policy.request()
    XCTAssertEqual(waits.count, 1)
    policy.invalidate()
    policy.request()
    await settle()
    XCTAssertEqual(waits.count, 2)
    waits[0].resume(returning: false)
    await settle()
    policy.request()
    await settle()
    XCTAssertEqual(waits.count, 2)
    waits[1].resume(returning: true)
    await settle()
    policy.stop()
  }

  func testExpiredPreparationIsReplacedWhileRecentlyUsed() async throws {
    var preparations = 0
    let policy = GrokPreparationController(initiallyLocked: false, eligible: { true },
      prepare: { preparations += 1; return true }, discard: {},
      refreshInterval: .milliseconds(30), keepWarmWindow: .milliseconds(200))
    policy.request()
    try await Task.sleep(for: .milliseconds(120))
    XCTAssertGreaterThanOrEqual(preparations, 3)
    // Without new activity, refreshes stop once the keep-warm window passes.
    try await Task.sleep(for: .milliseconds(250))
    let settled = preparations
    try await Task.sleep(for: .milliseconds(120))
    XCTAssertEqual(preparations, settled)
    policy.stop()
  }

  func testInvalidationCancelsPendingRefresh() async throws {
    var preparations = 0
    let policy = GrokPreparationController(initiallyLocked: false, eligible: { true },
      prepare: { preparations += 1; return true }, discard: {},
      refreshInterval: .milliseconds(30))
    policy.request()
    await settle()
    policy.setSleeping(true)
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertEqual(preparations, 1)
    policy.stop()
  }
}

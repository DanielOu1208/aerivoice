import Foundation
import XCTest
@testable import AeriVoice

@MainActor
final class LocalModelControllerTests: XCTestCase {
  func testCancelledDownloadHandlesURLSessionCancellation() async {
    let controller = LocalModelController(assets: SuspendedAvailabilityAssets(), observeMemoryPressure: false)
    controller.download()
    controller.cancelDownload()
    for _ in 0..<100 { await Task.yield() }
    XCTAssertEqual(controller.state, .missing)
  }

  func testPressureDoesNotClaimAMissingModelIsDownloaded() async {
    let assets = SuspendedAvailabilityAssets(installed: false, suspendFirst: false)
    let controller = LocalModelController(assets: assets, observeMemoryPressure: false)
    controller.releaseForPressure()
    for _ in 0..<100 { await Task.yield() }
    XCTAssertEqual(controller.state, .missing)
  }

  func testPressureDuringAvailabilityCheckDoesNotLeavePreparingStuck() async throws {
    let assets = SuspendedAvailabilityAssets()
    let runtime = LocalSpeechRuntime(makeEngine: { ImmediateLocalEngine() })
    let controller = LocalModelController(assets: assets, runtime: runtime, observeMemoryPressure: false)
    controller.select(true)
    await assets.waitForCheck()
    controller.releaseForPressure()
    await assets.resumeCheck()
    for _ in 0..<100 { await Task.yield() }
    XCTAssertEqual(controller.state, .available)
    XCTAssertFalse(controller.isReady)
    controller.prepareIfNeeded()
    for _ in 0..<100 where !controller.isReady { await Task.yield() }
    XCTAssertTrue(controller.isReady)
    controller.select(false)
  }
}

private actor SuspendedAvailabilityAssets: LocalModelAssetManaging {
  var pending: CheckedContinuation<Bool, Never>?
  var waiting: CheckedContinuation<Void, Never>?
  let installed: Bool
  var firstCheck: Bool
  init(installed: Bool = true, suspendFirst: Bool = true) {
    self.installed = installed; self.firstCheck = suspendFirst
  }
  func isInstalled() async -> Bool {
    guard firstCheck else { return installed }
    firstCheck = false
    return await withCheckedContinuation {
      pending = $0
      waiting?.resume(); waiting = nil
    }
  }
  func waitForCheck() async {
    if pending != nil { return }
    await withCheckedContinuation { waiting = $0 }
  }
  func resumeCheck() { pending?.resume(returning: true); pending = nil }
  func verifiedDirectory() async throws -> URL { URL(fileURLWithPath: "/unused") }
  func download(progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
    throw URLError(.cancelled)
  }
  func remove() async throws {}
}

private actor ImmediateLocalEngine: LocalSpeechEngine {
  func load(from directory: URL) async throws {}
  func reset() async {}
  func setVocabulary(_ words: [String]) async {}
  func process(_ samples: [Float]) async throws -> String { "" }
  func finish() async throws -> String { "" }
}

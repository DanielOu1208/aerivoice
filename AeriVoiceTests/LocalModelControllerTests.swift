import Foundation
import XCTest
@testable import AeriVoice

@MainActor
final class LocalModelControllerTests: XCTestCase {
  func testResumeCannotRaceRemovalEvenDuringMemoryPressure() async {
    let assets = SuspendedRemovalAssets()
    let controller = LocalModelController(assets: assets, observeMemoryPressure: false)
    controller.select(false)
    await controller.waitForPreparation()
    XCTAssertEqual(controller.state, .partial)
    controller.remove()
    XCTAssertEqual(controller.state, .removing)
    XCTAssertFalse(controller.canRemove)
    controller.download()
    await assets.waitUntilRemovalStarts()
    controller.releaseForPressure()
    controller.download()
    XCTAssertEqual(controller.state, .removing)
    let calls = await assets.downloadCalls
    XCTAssertEqual(calls, 0)
    await assets.finishRemoval()
    await controller.waitForPreparation()
    XCTAssertEqual(controller.state, .missing)
    XCTAssertTrue(controller.canRemove)
  }

  func testCancelledDownloadHandlesURLSessionCancellation() async {
    let controller = LocalModelController(
      assets: SuspendedAvailabilityAssets(installed: false, suspendFirst: false), observeMemoryPressure: false)
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

private actor SuspendedRemovalAssets: LocalModelAssetManaging {
  private var partial = true
  private var removal: CheckedContinuation<Void, Never>?
  private var started: CheckedContinuation<Void, Never>?
  private(set) var downloadCalls = 0
  func isInstalled() async -> Bool { false }
  func hasPartialDownload() async -> Bool { partial }
  func verifiedDirectory() async throws -> URL { URL(fileURLWithPath: "/unused") }
  func download(progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
    downloadCalls += 1
    return URL(fileURLWithPath: "/unused")
  }
  func remove() async throws {
    await withCheckedContinuation {
      removal = $0
      started?.resume(); started = nil
    }
    partial = false
  }
  func waitUntilRemovalStarts() async {
    if removal != nil { return }
    await withCheckedContinuation { started = $0 }
  }
  func finishRemoval() { removal?.resume(); removal = nil }
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
  func hasPartialDownload() async -> Bool { false }
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

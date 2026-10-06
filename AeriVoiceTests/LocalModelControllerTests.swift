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

  func testDownloadProgressChangesTheStateOncePerPercent() async {
    // URLSession reports every chunk; each state change rebuilds the status menu.
    let controller = LocalModelController(
      assets: ChunkedDownloadAssets(), observeMemoryPressure: false)
    var progress: [Double] = []
    let observation = controller.$state.sink { state in
      if case .downloading(let value) = state { progress.append(value) }
    }
    controller.download()
    while controller.isDownloading { await Task.yield() }
    for _ in 0..<100 { await Task.yield() }
    observation.cancel()
    XCTAssertEqual(controller.state, .available)
    XCTAssertLessThanOrEqual(progress.count, 102)
    XCTAssertGreaterThanOrEqual(progress.count, 50)
    XCTAssertEqual(progress, progress.sorted())
    XCTAssertGreaterThanOrEqual(progress.last ?? 0, 0.99)
  }

  func testSelectingALoadedModelAgainNeitherVerifiesItNorLeavesReady() async {
    // Launch, wake and every settings change select the model again.
    let assets = CountingAssets()
    let runtime = LocalSpeechRuntime(makeEngine: { ImmediateLocalEngine() })
    let controller = LocalModelController(assets: assets, runtime: runtime, observeMemoryPressure: false)
    controller.select(true)
    await controller.waitForPreparation()
    XCTAssertTrue(controller.isReady)
    var states: [LocalModelController.State] = []
    let observation = controller.$state.dropFirst().sink { states.append($0) }
    for _ in 0..<3 {
      controller.select(true)
      XCTAssertTrue(controller.isReady)
      await controller.waitForPreparation()
    }
    observation.cancel()
    XCTAssertTrue(controller.isReady)
    XCTAssertEqual(states, [])
    var verifications = await assets.verifications
    XCTAssertEqual(verifications, 1)

    // Released under memory pressure, it is verified again before it is loaded again.
    controller.releaseForPressure()
    await controller.waitForPreparation()
    XCTAssertFalse(controller.isReady)
    controller.select(true)
    await controller.waitForPreparation()
    XCTAssertTrue(controller.isReady)
    verifications = await assets.verifications
    XCTAssertEqual(verifications, 2)

    // Turned off, it is unloaded, and turning it back on verifies it again.
    controller.select(false)
    await controller.waitForPreparation()
    XCTAssertFalse(controller.isReady)
    controller.select(true)
    await controller.waitForPreparation()
    XCTAssertTrue(controller.isReady)
    verifications = await assets.verifications
    XCTAssertEqual(verifications, 3)
    controller.select(false)
  }
}

private actor ChunkedDownloadAssets: LocalModelAssetManaging {
  private var installed = false
  func isInstalled() async -> Bool { installed }
  func hasPartialDownload() async -> Bool { false }
  func verifiedDirectory() async throws -> URL { URL(fileURLWithPath: "/unused") }
  func download(progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
    progress(0)
    for chunk in 1...10_000 {
      progress(min(0.999, Double(chunk) / 10_000))
      if chunk % 500 == 0 { await Task.yield() }
    }
    installed = true
    progress(1)
    return URL(fileURLWithPath: "/unused")
  }
  func remove() async throws {}
}

private actor CountingAssets: LocalModelAssetManaging {
  private(set) var verifications = 0
  func isInstalled() async -> Bool { true }
  func hasPartialDownload() async -> Bool { false }
  func verifiedDirectory() async throws -> URL {
    verifications += 1
    return URL(fileURLWithPath: "/unused")
  }
  func download(progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
    URL(fileURLWithPath: "/unused")
  }
  func remove() async throws {}
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

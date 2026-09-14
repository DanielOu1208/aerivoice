import CryptoKit
import Foundation
import XCTest

@testable import AeriVoice

final class LocalModelAssetsTests: XCTestCase {
  @MainActor
  func testCancelledPartialDownloadCanResumeWithoutFetchingVerifiedFilesAgain() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = FixtureDownload(suspendCall: 2)
    let assets = store(root, source)
    let controller = LocalModelController(assets: assets, observeMemoryPressure: false)
    controller.download()
    let deadline = Date().addingTimeInterval(5)
    while await source.calls < 2, Date() < deadline { await Task.yield() }
    let startedCalls = await source.calls
    XCTAssertEqual(startedCalls, 2)
    await controller.cancelDownloadAndWait()
    XCTAssertFalse(controller.isDownloading)
    XCTAssertEqual(controller.state, .partial)
    XCTAssertFalse(controller.assetsInstalled)
    XCTAssertTrue(controller.canRemove)

    controller.download()
    while controller.isDownloading, Date() < deadline { await Task.yield() }
    XCTAssertFalse(controller.isDownloading)
    XCTAssertEqual(controller.state, .available)
    let calls = await source.calls
    XCTAssertEqual(calls, 3, "Resume must reuse the first verified file")
    let partial = await assets.hasPartialDownload()
    XCTAssertFalse(partial)
  }

  @MainActor
  func testPartialDownloadIsRemovableAfterRelaunchWithoutFinishingDownload() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = FixtureDownload(failCall: 2)
    do {
      _ = try await store(root, source).download { _ in }
      XCTFail("Expected interrupted download")
    } catch FixtureDownload.Failure.interrupted {}

    // New store and controller discover staging on disk, without in-memory download history.
    let restoredAssets = store(root, source)
    let controller = LocalModelController(assets: restoredAssets, observeMemoryPressure: false)
    controller.select(true)
    await controller.waitForPreparation()
    XCTAssertEqual(controller.state, .partial)
    XCTAssertFalse(controller.isReady)
    controller.remove()
    await controller.waitForPreparation()
    XCTAssertEqual(controller.state, .missing)
    let partial = await restoredAssets.hasPartialDownload()
    XCTAssertFalse(partial)
    let calls = await source.calls
    XCTAssertEqual(calls, 2, "Removing staged files must not download anything")
  }

  func testPinnedManifestHasEveryAssetAndExpectedSize() {
    let manifest = LocalModelAssets.manifest
    XCTAssertEqual(manifest.assets.count, 22)
    XCTAssertEqual(manifest.totalBytes, 610_993_681)
    XCTAssertEqual(manifest.revision, "1a41b75758b0337ff67db7d5408280aaaf23074e")
    XCTAssertEqual(manifest.engineVersion, "0.15.7")
    XCTAssertEqual(Set(manifest.assets.map(\.path)).count, 22)
    XCTAssertTrue(manifest.assets.allSatisfy { $0.sha256.count == 64 })
    XCTAssertTrue(manifest.assets.contains { $0.path == "tokenizer.json" })
    XCTAssertTrue(manifest.assets.contains { $0.path == "encoder.mlmodelc/weights/weight.bin" })
  }

  func testInstallVerifyAndRemove() async throws {
    let root = temporaryRoot()
    defer {
      if FileManager.default.fileExists(atPath: root.path) { try? FileManager.default.removeItem(at: root) }
    }
    let source = FixtureDownload()
    let assets = store(root, source)
    let before = await assets.isInstalled()
    XCTAssertFalse(before)
    let installed = try await assets.download { _ in }
    XCTAssertEqual(installed.path, root.appendingPathComponent("installed").path)
    let verified = try await assets.verifiedDirectory()
    XCTAssertEqual(verified, installed)
    let count = await source.calls
    XCTAssertEqual(count, 2)
    _ = try await assets.download { _ in }
    let reusedCount = await source.calls
    XCTAssertEqual(reusedCount, 2)
    try await assets.remove()
    let after = await assets.isInstalled()
    XCTAssertFalse(after)
  }

  func testSameSizeCorruptionIsRejectedBeforeRuntimeLoadAndRepaired() async throws {
    let root = temporaryRoot()
    defer {
      if FileManager.default.fileExists(atPath: root.path) { try? FileManager.default.removeItem(at: root) }
    }
    let source = FixtureDownload()
    let assets = store(root, source)
    let installed = try await assets.download { _ in }
    try Data("bad".utf8).write(to: installed.appendingPathComponent("weights/a.bin"))
    do {
      _ = try await assets.verifiedDirectory()
      XCTFail("Same-size corruption must fail full verification")
    } catch LocalModelAssets.AssetError.corruptFile(let path) {
      XCTAssertEqual(path, "weights/a.bin")
    }
    _ = try await assets.download { _ in }
    _ = try await assets.verifiedDirectory()
  }

  func testVerifiedRecordContainsMeasuredFilesAndPinnedRevision() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let assets = store(root, FixtureDownload())
    let directory = try await assets.download { _ in }
    let record = try await assets.verify()
    XCTAssertEqual(record.directory, directory)
    XCTAssertEqual(record.files, manifest().assets)
    XCTAssertEqual(record.verifiedRevision, "test-revision")
  }

  func testExternalChangedFilesHaveNoVerifiedRevisionAndCannotUsePinnedPolicy() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let assets = store(root, FixtureDownload())
    let directory = try await assets.download { _ in }
    let changed = Data("different variant".utf8)
    try changed.write(to: directory.appendingPathComponent("weights/a.bin"))
    let record = try await assets.verify(policy: .inventoryOnly)
    XCTAssertNil(record.verifiedRevision)
    XCTAssertEqual(record.files.first?.size, Int64(changed.count))
    XCTAssertEqual(record.files.first?.sha256,
      SHA256.hash(data: changed).map { String(format: "%02x", $0) }.joined())
    do {
      _ = try await assets.verify(policy: .matchingManifest)
      XCTFail("External pinned models must match every hash")
    } catch LocalModelAssets.AssetError.corruptFile(let path) {
      XCTAssertEqual(path, "weights/a.bin")
    }
  }

  func testExternalMatchingFilesDoNotNeedInstallationMarker() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let assets = store(root, FixtureDownload())
    let directory = try await assets.download { _ in }
    try FileManager.default.removeItem(at: directory.appendingPathComponent(".aerivoice-verified.json"))
    let record = try await assets.verify(policy: .matchingManifest)
    XCTAssertEqual(record.verifiedRevision, "test-revision")
    do {
      _ = try await assets.verify()
      XCTFail("App installations still require their marker")
    } catch LocalModelAssets.AssetError.notInstalled {}
  }

  func testExternalInventoryRejectsMissingFilesSymlinksAndExtraBundles() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let assets = store(root, FixtureDownload())
    let directory = try await assets.download { _ in }
    let file = directory.appendingPathComponent("weights/a.bin")
    try FileManager.default.removeItem(at: file)
    do {
      _ = try await assets.verify(policy: .inventoryOnly)
      XCTFail("Missing required files must fail even for unpinned variants")
    } catch {}
    try FileManager.default.createSymbolicLink(at: file,
      withDestinationURL: directory.appendingPathComponent("tokenizer.json"))
    do {
      _ = try await assets.verify(policy: .inventoryOnly)
      XCTFail("External variants must reject symbolic links")
    } catch LocalModelAssets.AssetError.unsafePath {}
    try FileManager.default.removeItem(at: file)
    try Data("abc".utf8).write(to: file)
    try FileManager.default.createDirectory(
      at: directory.appendingPathComponent("rogue.mlmodelc"), withIntermediateDirectories: true)
    do {
      _ = try await assets.verify(policy: .inventoryOnly)
      XCTFail("External variants must reject unlisted bundles")
    } catch LocalModelAssets.AssetError.unexpectedFile(let path) {
      XCTAssertEqual(path, "rogue.mlmodelc")
    }
  }

  func testOptionalRogueDecoderBundleIsRejectedBeforeRuntimeLoad() async throws {
    let root = temporaryRoot()
    defer {
      if FileManager.default.fileExists(atPath: root.path) { try? FileManager.default.removeItem(at: root) }
    }
    let source = FixtureDownload()
    let assets = store(root, source)
    let installed = try await assets.download { _ in }
    let rogue = installed.appendingPathComponent("decoder_int8.mlmodelc", isDirectory: true)
    try FileManager.default.createDirectory(at: rogue, withIntermediateDirectories: true)
    try Data("unverified".utf8).write(to: rogue.appendingPathComponent("coremldata.bin"))
    do {
      _ = try await assets.verifiedDirectory()
      XCTFail("An optional decoder bundle must not bypass the pinned manifest")
    } catch LocalModelAssets.AssetError.unexpectedFile(let path) {
      XCTAssertEqual(path, "decoder_int8.mlmodelc")
    }
    let installedStatus = await assets.isInstalled()
    XCTAssertFalse(installedStatus)
    _ = try await assets.download { _ in }
    _ = try await assets.verifiedDirectory()
    XCTAssertFalse(FileManager.default.fileExists(atPath: rogue.path))
  }

  func testUnexpectedStagedFileCannotBePromoted() async throws {
    let root = temporaryRoot()
    defer {
      if FileManager.default.fileExists(atPath: root.path) { try? FileManager.default.removeItem(at: root) }
    }
    let source = FixtureDownload(failCall: 2)
    let assets = store(root, source)
    do {
      _ = try await assets.download { _ in }
      XCTFail("Injected request must fail")
    } catch FixtureDownload.Failure.interrupted {}
    let staging = root.appendingPathComponent(".installed.staging-test-revision", isDirectory: true)
    try Data("unverified".utf8).write(to: staging.appendingPathComponent("weights/extra.bin"))
    do {
      _ = try await assets.download { _ in }
      XCTFail("Staging must have an exact inventory before promotion")
    } catch LocalModelAssets.AssetError.unexpectedFile(let path) {
      XCTAssertEqual(path, "weights/extra.bin")
    }
    let installed = await assets.isInstalled()
    XCTAssertFalse(installed)
  }

  func testRetryReusesOnlyVerifiedStagedFiles() async throws {
    let root = temporaryRoot()
    defer {
      if FileManager.default.fileExists(atPath: root.path) { try? FileManager.default.removeItem(at: root) }
    }
    let source = FixtureDownload(failCall: 2)
    let assets = store(root, source)
    do {
      _ = try await assets.download { _ in }
      XCTFail("Injected request must fail")
    } catch FixtureDownload.Failure.interrupted {}
    let partial = await assets.isInstalled()
    XCTAssertFalse(partial)
    _ = try await assets.download { _ in }
    let calls = await source.calls
    XCTAssertEqual(calls, 3, "Retry should preserve the first verified file")
    _ = try await assets.verifiedDirectory()
  }

  func testCorruptDownloadNeverBecomesInstalledAndCanRetry() async throws {
    let root = temporaryRoot()
    defer {
      if FileManager.default.fileExists(atPath: root.path) { try? FileManager.default.removeItem(at: root) }
    }
    let source = FixtureDownload(corruptCall: 2)
    let assets = store(root, source)
    do {
      _ = try await assets.download { _ in }
      XCTFail("Downloaded bytes must match SHA-256")
    } catch LocalModelAssets.AssetError.corruptFile {}
    let partial = await assets.isInstalled()
    XCTAssertFalse(partial)
    _ = try await assets.download { _ in }
    let calls = await source.calls
    XCTAssertEqual(calls, 3)
  }

  func testCancelledTaskDoesNotStartNetworkOrInstall() async throws {
    let root = temporaryRoot()
    defer {
      if FileManager.default.fileExists(atPath: root.path) { try? FileManager.default.removeItem(at: root) }
    }
    let source = FixtureDownload()
    let assets = store(root, source)
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await assets.download { _ in }
    }
    do {
      _ = try await task.value
      XCTFail("Cancelled download must throw")
    } catch is CancellationError {}
    let calls = await source.calls
    XCTAssertEqual(calls, 0)
    let installed = await assets.isInstalled()
    XCTAssertFalse(installed)
    _ = try await assets.download { _ in }
  }

  func testInFlightDownloadBlocksRemovalAndCancellationReleasesOperation() async throws {
    let root = temporaryRoot()
    defer {
      if FileManager.default.fileExists(atPath: root.path) { try? FileManager.default.removeItem(at: root) }
    }
    let source = SuspendedDownload()
    let assets = LocalModelAssets(directory: root.appendingPathComponent("installed"), manifest: manifest()) {
      try await source.fetch($0, progress: $1)
    }
    let task = Task { try await assets.download { _ in } }
    await source.waitUntilStarted()
    do {
      try await assets.remove()
      XCTFail("Removal must not race an active download")
    } catch LocalModelAssets.AssetError.busy {}
    task.cancel()
    do {
      _ = try await task.value
      XCTFail("In-flight cancellation must propagate")
    } catch is CancellationError {}
    try await assets.remove()
    let installed = await assets.isInstalled()
    XCTAssertFalse(installed)
  }

  func testTraversalManifestIsRejectedBeforeNetwork() async throws {
    let root = temporaryRoot()
    defer {
      if FileManager.default.fileExists(atPath: root.path) { try? FileManager.default.removeItem(at: root) }
    }
    let source = FixtureDownload()
    let invalid = manifest(paths: ["../escape"])
    let assets = LocalModelAssets(directory: root.appendingPathComponent("installed"), manifest: invalid) {
      try await source.fetch($0, progress: $1)
    }
    do {
      _ = try await assets.download { _ in }
      XCTFail("Traversal must be rejected")
    } catch LocalModelAssets.AssetError.invalidManifest {}
    let calls = await source.calls
    XCTAssertEqual(calls, 0)
  }

  private func temporaryRoot() -> URL {
    URL(fileURLWithPath: "/private/tmp", isDirectory: true)
      .appendingPathComponent("LocalModelAssetsTests-\(UUID().uuidString)")
  }

  private func store(_ root: URL, _ source: FixtureDownload) -> LocalModelAssets {
    LocalModelAssets(directory: root.appendingPathComponent("installed"), manifest: manifest()) {
      try await source.fetch($0, progress: $1)
    }
  }

  private func manifest(paths: [String] = ["weights/a.bin", "tokenizer.json"]) -> LocalModelManifest {
    let digest = SHA256.hash(data: Data("abc".utf8)).map { String(format: "%02x", $0) }.joined()
    return LocalModelManifest(
      repository: "test/model", revision: "test-revision", subfolder: "latin/560ms", engineVersion: "test",
      assets: paths.map { .init(path: $0, size: 3, sha256: digest) }
    )
  }
}

private actor FixtureDownload {
  enum Failure: Error { case interrupted }
  private(set) var calls = 0
  let failCall: Int?
  let corruptCall: Int?
  let suspendCall: Int?

  init(failCall: Int? = nil, corruptCall: Int? = nil, suspendCall: Int? = nil) {
    self.failCall = failCall
    self.corruptCall = corruptCall
    self.suspendCall = suspendCall
  }

  func fetch(_ url: URL, progress: @Sendable (Int64) -> Void) async throws -> URL {
    calls += 1
    if calls == suspendCall { try await Task.sleep(for: .seconds(30)) }
    if calls == failCall { throw Failure.interrupted }
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try Data((calls == corruptCall ? "bad" : "abc").utf8).write(to: file)
    progress(3)
    return file
  }
}

private actor SuspendedDownload {
  private var started = false
  private var waiter: CheckedContinuation<Void, Never>?

  func waitUntilStarted() async {
    if started { return }
    await withCheckedContinuation { waiter = $0 }
  }

  func fetch(_ url: URL, progress: @Sendable (Int64) -> Void) async throws -> URL {
    started = true
    waiter?.resume()
    waiter = nil
    try await Task.sleep(for: .seconds(30))
    throw URLError(.timedOut)
  }
}

import Foundation
import XCTest
@testable import AeriVoice

@MainActor
final class AppleSpeechTests: XCTestCase {
  func testPreparationNeverDownloadsAssets() async {
    let assets = FakeAppleSpeechAssets()
    let controller = AppleSpeechController(assets: assets, preferredLanguages: ["en-US"])
    controller.select(true, localeIdentifier: "")
    await controller.waitForPreparation()
    XCTAssertEqual(controller.localeIdentifier, "en-US")
    XCTAssertEqual(controller.state, .missing)
    XCTAssertFalse(controller.isReady)
    XCTAssertEqual(assets.downloadCount, 0)
  }

  func testUnsupportedPrimaryLanguageDoesNotFallBackToEnglish() async {
    let assets = FakeAppleSpeechAssets()
    let controller = AppleSpeechController(assets: assets, preferredLanguages: ["xx-XX", "en-US"])
    controller.select(true, localeIdentifier: "")
    await controller.waitForPreparation()
    XCTAssertNil(controller.suggestedLocaleIdentifier)
    XCTAssertEqual(controller.localeIdentifier, "")
    XCTAssertFalse(controller.isReady)
    controller.download()
    XCTAssertFalse(controller.isDownloading)
    XCTAssertEqual(assets.downloadCount, 0)
  }

  func testInstalledExplicitLocaleCanBeReadyWithoutMatchingMacLanguage() async {
    let assets = FakeAppleSpeechAssets()
    assets.hasAssets = true
    let controller = AppleSpeechController(assets: assets, preferredLanguages: ["xx-XX"])
    controller.select(true, localeIdentifier: "en-US")
    await controller.waitForPreparation()
    XCTAssertTrue(controller.isReady)
    controller.select(false, localeIdentifier: "en-US")
    await controller.waitForPreparation()
    XCTAssertTrue(controller.assetsInstalled)
    XCTAssertFalse(controller.isReady)
  }

  func testSwitchingSelectionKeepsSystemDownloadTracked() async {
    let assets = FakeAppleSpeechAssets()
    let controller = AppleSpeechController(assets: assets, preferredLanguages: ["en-US"])
    controller.select(true, localeIdentifier: "")
    await controller.waitForPreparation()
    controller.download()
    await assets.waitUntilDownloadStarts()
    controller.select(false, localeIdentifier: "en-US")
    await controller.waitForPreparation()
    XCTAssertTrue(controller.isDownloading)
    controller.download()
    XCTAssertEqual(assets.downloadCount, 1)
    assets.completeDownload()
    for _ in 0..<100 where controller.isDownloading { await Task.yield() }
    await controller.waitForPreparation()
    XCTAssertFalse(controller.isDownloading)
    XCTAssertTrue(controller.assetsInstalled)
    XCTAssertFalse(controller.isReady)
  }

  func testReservationFailureIsReportedWithoutDownloading() async {
    let assets = FakeAppleSpeechAssets()
    assets.hasAssets = true
    assets.installationError = NSError(domain: "test", code: 1,
      userInfo: [NSLocalizedDescriptionKey: "Reservation unavailable"])
    let controller = AppleSpeechController(assets: assets, preferredLanguages: ["en-US"])
    controller.select(true, localeIdentifier: "en-US")
    await controller.waitForPreparation()
    XCTAssertEqual(controller.state, .failed("Reservation unavailable"))
    XCTAssertFalse(controller.isReady)
    XCTAssertEqual(assets.downloadCount, 0)
  }

  func testNewPreparationWaitsForPreviousReservationAndIgnoresItsResult() async {
    let assets = FakeAppleSpeechAssets()
    assets.suspendInstallation = true
    let controller = AppleSpeechController(assets: assets, preferredLanguages: ["en-US"])
    controller.select(true, localeIdentifier: "en-US")
    while assets.installationCount == 0 { await Task.yield() }
    controller.select(true, localeIdentifier: "en-US")
    for _ in 0..<20 { await Task.yield() }
    XCTAssertEqual(assets.installationCount, 1)
    XCTAssertFalse(controller.isReady)
    assets.hasAssets = true
    assets.resumeInstallation(returning: false)
    await controller.waitForPreparation()
    XCTAssertEqual(assets.installationCount, 2)
    XCTAssertTrue(controller.isReady)
    XCTAssertEqual(assets.downloadCount, 0)
  }

  func testRevisionsReplaceAudioRangesAndRetainEarlierFinalText() {
    var text = AppleTranscriptAccumulator()
    text.update(start: 0, end: 1, text: "Hello ", isFinal: true)
    text.update(start: 1, end: 3, text: "wrong", isFinal: false)
    text.update(start: 1, end: 2, text: "world", isFinal: false)
    XCTAssertEqual(text.snapshot.confirmed, "Hello ")
    XCTAssertEqual(text.snapshot.provisional, "world")
    text.update(start: 1, end: 2, text: "world.", isFinal: true)
    XCTAssertEqual(text.text, "Hello world.")
    XCTAssertEqual(text.snapshot.provisional, "")
    text.update(start: .nan, end: 5, text: "invalid", isFinal: true)
    XCTAssertEqual(text.text, "Hello world.")
  }
}

@MainActor
private final class FakeAppleSpeechAssets: AppleSpeechAssetManaging {
  let isAvailable = true
  var hasAssets = false
  var installationError: Error?
  var suspendInstallation = false
  var installationCount = 0
  private var installation: CheckedContinuation<Bool, Never>?
  var downloadCount = 0
  private var started: CheckedContinuation<Void, Never>?
  private var completion: CheckedContinuation<Void, Never>?
  func supportedLocales() async -> [Locale] { [Locale(identifier: "en-US")] }
  func equivalentLocale(_ locale: Locale) async -> Locale? {
    locale.identifier == "en-US" ? locale : nil
  }
  func installed(_ locale: Locale) async throws -> Bool {
    installationCount += 1
    if let installationError { throw installationError }
    if suspendInstallation {
      return await withCheckedContinuation { installation = $0 }
    }
    return hasAssets
  }
  func resumeInstallation(returning result: Bool) {
    suspendInstallation = false
    installation?.resume(returning: result)
    installation = nil
  }
  func download(_ locale: Locale, progress: @escaping @MainActor (Double) -> Void) async throws {
    downloadCount += 1
    progress(0.5)
    await withCheckedContinuation { continuation in
      completion = continuation
      started?.resume()
      started = nil
    }
    hasAssets = true
  }
  func waitUntilDownloadStarts() async {
    if completion != nil { return }
    await withCheckedContinuation { started = $0 }
  }
  func completeDownload() {
    completion?.resume()
    completion = nil
  }
}

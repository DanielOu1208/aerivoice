import Foundation
import Sparkle
import XCTest
@testable import AeriVoice

@MainActor
final class SparkleUpdateEngineTests: XCTestCase {
  func testQuietSettingsProgressKeepsCancellationWithoutOpeningWindow() {
    let driver = SparkleUserDriver(hostBundle: .main)
    driver.networkAllowed = { true }
    driver.showsCheckingProgress = false
    var cancellations = 0
    driver.beginCycle()
    driver.showUserInitiatedUpdateCheck { cancellations += 1 }
    XCTAssertEqual(cancellations, 0)
    driver.cancelCurrentCycle()
    XCTAssertEqual(cancellations, 1)
  }

  func testCancellationSurvivesDelayedInstallerProbeStartingCycle() {
    let driver = SparkleUserDriver(hostBundle: .main)
    driver.networkAllowed = { true }
    driver.cancelCurrentCycle()
    driver.beginCycle()
    var cancellations = 0
    driver.showUserInitiatedUpdateCheck { cancellations += 1 }
    XCTAssertTrue(driver.cancelledByApp)
    XCTAssertEqual(cancellations, 1)
    driver.finishCycle()
    XCTAssertFalse(driver.cancelledByApp)
  }

  func testReplyIsConsumedBeforeReentrantInvocation() {
    var values: [Int] = []
    var reply: UpdateReply<Int>!
    reply = UpdateReply { value in
      values.append(value)
      XCTAssertFalse(reply.resolve(2))
    }
    XCTAssertTrue(reply.resolve(1))
    XCTAssertFalse(reply.resolve(3))
    XCTAssertEqual(values, [1])
  }

  func testInvalidatedReplyDoesNotRunShutdownSideEffects() {
    let reply = UpdateReply<Int> { _ in XCTFail("Stale reply invoked") }
    reply.invalidate()
    XCTAssertFalse(reply.resolve(1, before: { XCTFail("Stale reply side effect") }))
  }

  func testOfflineOfferDismissesButReadyInstallationCancelsStaging() {
    XCTAssertEqual(SparkleUserDriver.offlineChoice(for: .offering), .dismiss)
    XCTAssertEqual(SparkleUserDriver.offlineChoice(for: .readyToInstall), .skip)
    XCTAssertNil(SparkleUserDriver.offlineChoice(for: .preparing))
    XCTAssertNil(SparkleUserDriver.offlineChoice(for: .installing))
  }

  func testOfflineReadyReplyCancelsWithoutRequestingRestart() {
    let driver = SparkleUserDriver(hostBundle: .main)
    driver.networkAllowed = { false }
    driver.emit = { event in
      if case .restartRequested = event { XCTFail("Offline must not restart") }
    }
    var choices: [SPUUserUpdateChoice] = []
    driver.showReady(toInstallAndRelaunch: { choices.append($0) })
    driver.cancelCurrentCycle()
    XCTAssertEqual(choices, [.skip])
  }

  func testOfflineAcknowledgesDeferredErrorOnceAndDiscardsPresentation() {
    let driver = SparkleUserDriver(hostBundle: .main)
    driver.networkAllowed = { true }
    driver.presentationAllowed = { false }
    var acknowledgements = 0
    driver.showUpdaterError(NSError(domain: "test", code: 1)) { acknowledgements += 1 }
    XCTAssertEqual(acknowledgements, 0)
    driver.cancelCurrentCycle()
    driver.cancelCurrentCycle()
    driver.presentationAllowed = { true }
    driver.resumeDeferredPresentation()
    XCTAssertEqual(acknowledgements, 1)
  }

  func testDeferredReadyReplyRemainsCancellableWithoutPresentation() {
    let driver = SparkleUserDriver(hostBundle: .main)
    driver.networkAllowed = { true }
    driver.presentationAllowed = { false }
    var choices: [SPUUserUpdateChoice] = []
    driver.showReady(toInstallAndRelaunch: { choices.append($0) })
    XCTAssertTrue(choices.isEmpty)
    driver.cancelCurrentCycle()
    driver.presentationAllowed = { true }
    driver.resumeDeferredPresentation()
    XCTAssertEqual(choices, [.skip])
  }
}

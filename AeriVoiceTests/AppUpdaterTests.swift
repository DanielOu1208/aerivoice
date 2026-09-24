import Foundation
import XCTest
@testable import AeriVoice

@MainActor
final class AppUpdaterTests: XCTestCase {
  private let update = AvailableUpdate(build: "2026092305", version: "0.1.0-beta.11")

  func testDoesNotStartOrCheckBeforeSetupOrWhileOffline() {
    let f = fixture()
    f.context(setup: false)
    f.updater.checkForUpdates()
    XCTAssertEqual(f.engine.starts, 0)
    XCTAssertEqual(f.engine.checks, 0)
    XCTAssertFalse(f.engine.allowsNetwork?() ?? true)
    f.context(offline: true)
    XCTAssertEqual(f.engine.starts, 0)
    f.context()
    XCTAssertEqual(f.engine.starts, 1)
    XCTAssertTrue(f.updater.canCheck)
    f.context()
    XCTAssertEqual(f.engine.starts, 1)
  }

  func testOfflineWaitsForActualCycleCompletionAndBlocksNewRequests() async {
    let f = fixture()
    f.context()
    f.updater.checkForUpdates()
    f.context(offline: true, changing: true)
    var settled = false
    let transition = Task { await f.updater.prepareForOffline(); settled = true }
    await drainTasks()
    XCTAssertEqual(f.engine.cancellations, 1)
    XCTAssertFalse(settled)
    XCTAssertFalse(f.engine.allowsNetwork?() ?? true)
    f.updater.checkForUpdates()
    XCTAssertEqual(f.engine.checks, 1)
    // Merely closing a window / changing stage is not a finished request.
    f.engine.send(.stage(.idle))
    await drainTasks()
    XCTAssertFalse(settled)
    f.engine.finish()
    await transition.value
    XCTAssertTrue(settled)
    f.context(offline: true)
    XCTAssertFalse(f.updater.canCheck)
    XCTAssertEqual(f.updater.status, "Turn off Offline mode to check for updates.")
    f.context()
    XCTAssertTrue(f.updater.canCheck)
  }

  func testDisablingAlertsKeepsDailyChecksAndQuietAvailability() async {
    let f = fixture()
    f.context()
    f.updater.setShowsAlerts(false)
    f.discover(update)
    await drainTasks()
    XCTAssertTrue(f.engine.automaticallyChecks)
    XCTAssertEqual(f.updater.availableUpdate, update)
    XCTAssertEqual(f.updater.menuTitle, "Update Available…")
    XCTAssertTrue(f.notifier.posts.isEmpty)
    f.updater.setSettingsActive(true)
    XCTAssertEqual(f.engine.checks, 0)
    f.updater.checkForUpdates()
    XCTAssertEqual(f.engine.checks, 1)
  }

  func testDiscoveryDuringDictationWaitsForIdleBeforeNotification() async {
    let f = fixture()
    f.context(idle: false)
    f.discover(update)
    await drainTasks()
    XCTAssertTrue(f.notifier.posts.isEmpty)
    XCTAssertFalse(f.engine.allowsPresentation?() ?? true)
    f.context()
    await drainTasks()
    XCTAssertEqual(f.notifier.posts, [update])
  }

  func testLaterSnoozesNotificationAndSettingsPromptForOneDay() async {
    let f = fixture()
    f.context()
    f.engine.send(.found(update, userInitiated: true))
    f.engine.send(.choice(.later, update))
    f.engine.finish()
    f.updater.setSettingsActive(true)
    f.discover(update)
    await drainTasks()
    XCTAssertTrue(f.notifier.posts.isEmpty)
    XCTAssertEqual(f.engine.checks, 0)
    f.clock.date += 86_400
    f.discover(update)
    XCTAssertEqual(f.engine.checks, 1)
    XCTAssertEqual(f.engine.progressRequests, [false])
  }

  func testNotificationIsAtMostOnceADayAndNewVersionCanAlert() async {
    let f = fixture()
    f.context()
    f.discover(update)
    await drainTasks()
    f.discover(update)
    await drainTasks()
    XCTAssertEqual(f.notifier.posts.count, 1)
    f.clock.date += 86_400
    f.discover(update)
    await drainTasks()
    XCTAssertEqual(f.notifier.posts.count, 2)
    let next = AvailableUpdate(build: "2026092306", version: "0.1.0-beta.12")
    f.discover(next)
    await drainTasks()
    XCTAssertEqual(f.notifier.posts.last, next)
    XCTAssertEqual(f.notifier.posts.count, 3)
  }

  func testDeniedNotificationsStillOfferUpdateWhenSettingsOpens() async {
    let f = fixture()
    f.notifier.authorized = false
    f.context()
    f.discover(update)
    await drainTasks()
    XCTAssertEqual(f.updater.availableUpdate, update)
    f.updater.setSettingsActive(true)
    XCTAssertEqual(f.engine.checks, 1)
  }

  func testAutomaticSettingsCheckLosingFocusCancelsAndCannotPresent() {
    let f = fixture()
    f.context()
    f.updater.setSettingsActive(true)
    f.discover(update)
    XCTAssertEqual(f.engine.checks, 1)
    XCTAssertTrue(f.engine.allowsPresentation?() ?? false)
    f.updater.setSettingsActive(false)
    XCTAssertEqual(f.engine.cancellations, 1)
    XCTAssertFalse(f.engine.allowsPresentation?() ?? true)
    // A delayed feed response or idle transition must not activate the app.
    f.engine.send(.found(update, userInitiated: true))
    f.context(idle: false)
    f.context()
    XCTAssertFalse(f.engine.allowsPresentation?() ?? true)
  }

  func testPresentingNativeOfferTransfersFocusWithoutCancellingOffer() {
    let f = fixture()
    f.context()
    f.updater.setSettingsActive(true)
    f.discover(update)
    f.engine.send(.presentingOffer)
    f.updater.setSettingsActive(false)
    XCTAssertEqual(f.engine.cancellations, 0)
    XCTAssertTrue(f.engine.allowsPresentation?() ?? false)
  }

  func testPermissionRequestedOnlyOnceAfterSetupWhenSettingsIsActive() async {
    let f = fixture()
    f.updater.setSettingsActive(true)
    await drainTasks()
    XCTAssertEqual(f.notifier.permissionRequests, 0)
    f.context()
    await drainTasks()
    XCTAssertEqual(f.notifier.permissionRequests, 1)
    f.updater.setSettingsActive(false)
    f.updater.setSettingsActive(true)
    await drainTasks()
    XCTAssertEqual(f.notifier.permissionRequests, 1)
  }

  func testNotificationClickDuringDictationDefersExplicitCheck() {
    let f = fixture()
    f.context(idle: false)
    f.updater.openUpdateFromNotification()
    XCTAssertEqual(f.engine.checks, 0)
    f.context()
    XCTAssertEqual(f.engine.checks, 1)
  }

  func testRestartBlocksChecksAndOfflineUntilFailedInstallRecovers() {
    let f = fixture()
    f.context()
    f.engine.send(.restartRequested)
    XCTAssertTrue(f.updater.restartPending)
    XCTAssertFalse(f.updater.canCheck)
    XCTAssertFalse(f.updater.canEnterOffline)
    XCTAssertFalse(f.engine.allowsNetwork?() ?? true)
    f.engine.finish(error: "Installation failed")
    XCTAssertFalse(f.updater.restartPending)
    XCTAssertTrue(f.updater.canCheck)
    XCTAssertTrue(f.updater.canEnterOffline)
  }

  func testPreparingBlocksOfflineButReadyStageCanCancel() {
    let f = fixture()
    f.context()
    f.engine.send(.stage(.preparing))
    XCTAssertFalse(f.updater.canEnterOffline)
    f.engine.send(.stage(.readyToInstall))
    XCTAssertTrue(f.updater.canEnterOffline)
  }

  func testSkipClearsQuietNoticeButExplicitCheckCanRediscover() {
    let f = fixture()
    f.context()
    f.engine.send(.found(update, userInitiated: true))
    f.engine.send(.choice(.skip, update))
    f.engine.finish()
    XCTAssertNil(f.updater.availableUpdate)
    f.updater.checkForUpdates()
    f.engine.send(.found(update, userInitiated: true))
    XCTAssertEqual(f.updater.availableUpdate, update)
  }

  func testFailedCheckDoesNotAdvanceSuccessfulCheckDate() {
    let f = fixture()
    f.context()
    f.engine.send(.feedLoaded)
    let successful = f.updater.lastSuccessfulCheck
    f.clock.date += 60
    f.engine.finish(error: "Connection failed")
    XCTAssertEqual(f.updater.lastSuccessfulCheck, successful)
  }

  func testLateNotificationCompletionCannotClearANewerNotification() async {
    let f = fixture()
    f.notifier.suspendPost = true
    f.context()
    f.discover(update)
    await drainTasks()
    XCTAssertEqual(f.notifier.posts.count, 1)
    f.updater.setShowsAlerts(false)
    f.updater.setShowsAlerts(true)
    await drainTasks()
    XCTAssertEqual(f.notifier.posts.count, 1, "Only one OS request may be in flight")
    f.notifier.suspendPost = false
    f.notifier.pendingPost?.resume(returning: true)
    f.notifier.pendingPost = nil
    await drainTasks()
    XCTAssertEqual(f.notifier.posts.count, 2)
    XCTAssertEqual(f.notifier.delivered, update)
  }

  private func fixture() -> UpdaterFixture {
    let suite = "AppUpdaterTests.\(UUID().uuidString)"
    addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
    return UpdaterFixture(defaults: UserDefaults(suiteName: suite)!)
  }

  private func drainTasks() async {
    for _ in 0..<20 { await Task.yield() }
  }
}

@MainActor
private final class UpdaterFixture {
  let engine = FakeUpdateEngine()
  let notifier = FakeUpdateNotifier()
  let clock = UpdateTestClock()
  let updater: AppUpdater

  init(defaults: UserDefaults) {
    updater = AppUpdater(engine: engine, notifications: notifier, defaults: defaults, now: { [clock] in clock.date })
  }

  func context(setup: Bool = true, offline: Bool = false, changing: Bool = false, idle: Bool = true) {
    updater.updateContext(setupComplete: setup, offline: offline, changingOffline: changing, dictationIdle: idle)
  }

  func discover(_ update: AvailableUpdate) {
    engine.send(.stage(.checking))
    engine.send(.feedLoaded)
    engine.send(.found(update, userInitiated: false))
    engine.finish()
  }
}

@MainActor
private final class UpdateTestClock {
  var date = Date(timeIntervalSince1970: 1_790_000_000)
}

@MainActor
private final class FakeUpdateEngine: UpdateEngine {
  var onEvent: ((UpdateEngineEvent) -> Void)?
  var allowsNetwork: (() -> Bool)?
  var allowsPresentation: (() -> Bool)?
  var automaticallyChecks = true
  var canCheck = true
  var starts = 0
  var checks = 0
  var cancellations = 0
  var progressRequests: [Bool] = []

  func start() throws { starts += 1 }
  func checkForUpdates(showProgress: Bool) {
    checks += 1
    progressRequests.append(showProgress)
    canCheck = false
    send(.stage(.checking))
  }
  func cancelCurrentCycle() { cancellations += 1 }
  func settingsChanged() {}
  func resumeDeferredPresentation() {}
  func send(_ event: UpdateEngineEvent) { onEvent?(event) }
  func finish(error: String? = nil) { canCheck = true; send(.cycleFinished(error: error)) }
}

@MainActor
private final class FakeUpdateNotifier: UpdateNotifying {
  var permissionRequests = 0
  var posts: [AvailableUpdate] = []
  var delivered: AvailableUpdate?
  var authorized = true
  var suspendPost = false
  var pendingPost: CheckedContinuation<Bool, Never>?

  func requestPermission() async { permissionRequests += 1 }
  func post(_ update: AvailableUpdate) async -> Bool {
    posts.append(update)
    let posted: Bool
    if suspendPost { posted = await withCheckedContinuation { pendingPost = $0 } }
    else { posted = authorized }
    if posted { delivered = update }
    return posted
  }
  func clear() { delivered = nil }
}

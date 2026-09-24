import Foundation
import XCTest
@testable import AeriVoice

@MainActor
final class UsageStatsTests: XCTestCase {
  private var directory: URL!
  private var defaults: UserDefaults!
  private var suite: String!
  private var url: URL { directory.appending(path: "totals.json") }

  override func setUp() {
    super.setUp()
    directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    suite = "AeriVoiceTests.UsageStats.\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suite)!
  }

  override func tearDown() {
    try? FileManager.default.removeItem(at: directory)
    defaults.removePersistentDomain(forName: suite)
    super.tearDown()
  }

  func testLanguageAwareWordCounts() {
    XCTAssertEqual(UsageWordCounter.count("Hello, world! 42"), 3)
    XCTAssertEqual(UsageWordCounter.count("  … !!! 👋🏽 \n"), 0)
    XCTAssertGreaterThan(UsageWordCounter.count("我喜欢使用语音输入。"), 1)
    XCTAssertGreaterThan(UsageWordCounter.count("今日は良い天気です。"), 1)
    let chinese = "我喜欢语音输入"
    XCTAssertEqual(UsageWordCounter.count("Hello \(chinese) world"),
                   UsageWordCounter.count(chinese) + 2)
  }

  func testWeightedSpeedAndInvalidDuration() {
    var totals = UsageTotals()
    totals.add(words: 100, recordingSeconds: 60)
    totals.add(words: 10, recordingSeconds: 6)
    totals.add(words: 50, recordingSeconds: .nan)
    totals.add(words: 20, recordingSeconds: 0)
    XCTAssertEqual(totals.words, 180)
    XCTAssertEqual(totals.dictations, 4)
    XCTAssertEqual(totals.wordsPerMinute!, 100, accuracy: 0.001)
    XCTAssertEqual(totals.recordingSeconds, 66)
    XCTAssertTrue(totals.isValid)
    XCTAssertNil(UsageTotals().wordsPerMinute)
  }

  func testCompletionPersistsOnceWithoutTranscriptOrSessionHistory() async throws {
    let model = UsageStatsModel(defaults: defaults, url: url)
    let session = try XCTUnwrap(model.begin())
    model.complete(session, words: 120, recordingSeconds: 60, at: date("2026-09-21"))
    model.complete(session, words: 120, recordingSeconds: 60, at: date("2026-09-21"))
    await model.waitForPendingWrites()
    XCTAssertEqual(model.data.days["2026-09-21"]?.words, 120)
    let restored = UsageStatsModel(defaults: defaults, url: url)
    await restored.waitForPendingWrites()
    XCTAssertEqual(restored.data, model.data)
    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    XCTAssertEqual(Set(json.keys), ["version", "days"])
    let encoded = try String(contentsOf: url, encoding: .utf8)
    XCTAssertFalse(encoded.contains(session.id.uuidString))
  }

  func testDisableRejectsActiveAndQueuedSessionsButPreservesSavedTotals() async throws {
    let model = UsageStatsModel(defaults: defaults, url: url)
    let saved = try XCTUnwrap(model.begin())
    model.complete(saved, words: 10, recordingSeconds: 6, at: Date())
    await model.waitForPendingWrites()
    let active = try XCTUnwrap(model.begin())
    let queued = try XCTUnwrap(model.begin())
    model.complete(queued, words: 500, recordingSeconds: 60, at: Date())
    model.setEnabled(false)
    model.complete(active, words: 500, recordingSeconds: 60, at: Date())
    XCTAssertNil(model.begin())
    model.setEnabled(true)
    model.complete(active, words: 500, recordingSeconds: 60, at: Date())
    await model.waitForPendingWrites()
    XCTAssertEqual(UsageCalendar.summary(model.data, period: .all).totals.words, 10)
    let fresh = try XCTUnwrap(model.begin())
    model.complete(fresh, words: 20, recordingSeconds: 6, at: Date())
    await model.waitForPendingWrites()
    XCTAssertEqual(UsageCalendar.summary(model.data, period: .all).totals.words, 30)
  }

  func testClearRejectsActiveAndQueuedCompletionsAndAllowsNewSession() async throws {
    let model = UsageStatsModel(defaults: defaults, url: url)
    let active = try XCTUnwrap(model.begin())
    let queued = try XCTUnwrap(model.begin())
    model.complete(queued, words: 500, recordingSeconds: 60, at: Date())
    model.clear()
    model.complete(active, words: 500, recordingSeconds: 60, at: Date())
    await model.waitForPendingWrites()
    XCTAssertTrue(model.data.days.isEmpty)
    XCTAssertTrue(model.enabled)
    let restored = UsageStatsModel(defaults: defaults, url: url)
    await restored.waitForPendingWrites()
    XCTAssertTrue(restored.data.days.isEmpty)
    let fresh = try XCTUnwrap(model.begin())
    model.complete(fresh, words: 20, recordingSeconds: 6, at: Date())
    await model.waitForPendingWrites()
    XCTAssertEqual(UsageCalendar.summary(model.data, period: .all).totals.words, 20)
  }

  func testDiscardAndDisabledPreference() async throws {
    let model = UsageStatsModel(defaults: defaults, url: url)
    let session = try XCTUnwrap(model.begin())
    model.discard(session)
    model.complete(session, words: 10, recordingSeconds: 6, at: Date())
    await model.waitForPendingWrites()
    XCTAssertTrue(model.data.days.isEmpty)
    model.setEnabled(false)
    let restored = UsageStatsModel(defaults: defaults, url: url)
    await restored.waitForPendingWrites()
    XCTAssertFalse(restored.enabled)
    restored.clear()
    await restored.waitForPendingWrites()
    XCTAssertFalse(restored.enabled)
  }

  func testUnreadableDataIsPreservedUntilExplicitClear() async throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let original = Data("not valid json".utf8)
    try original.write(to: url)
    let model = UsageStatsModel(defaults: defaults, url: url)
    let session = try XCTUnwrap(model.begin())
    model.complete(session, words: 10, recordingSeconds: 6, at: Date())
    await model.waitForPendingWrites()
    XCTAssertNotNil(model.storageError)
    XCTAssertEqual(try Data(contentsOf: url), original)
    model.clear()
    await model.waitForPendingWrites()
    XCTAssertNil(model.storageError)
    XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
  }

  func testWriteFailureLeavesPublishedTotalsUnchanged() async throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let model = UsageStatsModel(defaults: defaults, url: url)
    await model.waitForPendingWrites()
    // A directory at the file path guarantees an atomic replacement failure.
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    let session = try XCTUnwrap(model.begin())
    model.complete(session, words: 10, recordingSeconds: 6, at: Date())
    await model.waitForPendingWrites()
    XCTAssertNotNil(model.storageError)
    XCTAssertTrue(model.data.days.isEmpty)
  }

  func testClearFailurePreservesDataAndReportsErrorUntilSuccessfulRetry() async throws {
    let model = UsageStatsModel(defaults: defaults, url: url)
    let session = try XCTUnwrap(model.begin())
    model.complete(session, words: 10, recordingSeconds: 6, at: Date())
    await model.waitForPendingWrites()
    let originalData = model.data
    let originalFile = try Data(contentsOf: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
    defer {
      try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    model.clear()
    await model.waitForPendingWrites()
    XCTAssertEqual(model.storageError, "Usage stats couldn’t be cleared. Your existing totals are still available.")
    XCTAssertEqual(model.data, originalData)
    XCTAssertEqual(try Data(contentsOf: url), originalFile)

    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    model.clear()
    await model.waitForPendingWrites()
    XCTAssertNil(model.storageError)
    XCTAssertTrue(model.data.days.isEmpty)
    XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
  }

  func testMalformedMagnitudesArePreservedAndRejectedOnLoad() async throws {
    let countOverflow = UsageStatsData(days: [
      "2026-09-21": UsageTotals(words: .max, dictations: 1),
      "2026-09-22": UsageTotals(words: 1, dictations: 1)
    ])
    let dictationOverflow = UsageStatsData(days: [
      "2026-09-21": UsageTotals(dictations: .max),
      "2026-09-22": UsageTotals(dictations: 1)
    ])
    let enormousDuration = UsageStatsData(days: [
      "2026-09-21": UsageTotals(words: 1, dictations: 1, recordingSeconds: 1e300, timedWords: 1)
    ])
    let durationOverflow = UsageStatsData(days: [
      "2026-09-21": UsageTotals(recordingSeconds: Double(Int64.max) * 0.75),
      "2026-09-22": UsageTotals(recordingSeconds: Double(Int64.max) * 0.75)
    ])
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for data in [countOverflow, dictationOverflow, enormousDuration, durationOverflow] {
      let original = try JSONEncoder().encode(data)
      try original.write(to: url)
      let model = UsageStatsModel(defaults: defaults, url: url)
      await model.waitForPendingWrites()
      XCTAssertNotNil(model.storageError)
      XCTAssertTrue(model.data.days.isEmpty)
      let session = try XCTUnwrap(model.begin())
      model.complete(session, words: 1, recordingSeconds: 1, at: Date())
      await model.waitForPendingWrites()
      XCTAssertEqual(try Data(contentsOf: url), original)
    }
  }

  func testOverflowingCompletionDoesNotChangeSavedOrPublishedTotals() async throws {
    let savedDay = UsageCalendar.dayKey(Date())
    let originalData = UsageStatsData(days: [savedDay: UsageTotals(words: .max, dictations: 1)])
    let store = UsageStatsStore(url: url)
    try await store.save(originalData)
    let originalFile = try Data(contentsOf: url)
    let model = UsageStatsModel(defaults: defaults, url: url)
    await model.waitForPendingWrites()

    // Cover both a daily addition and aggregate overflow across separate days.
    for completionDate in [Date(), Date().addingTimeInterval(2 * 86400)] {
      let session = try XCTUnwrap(model.begin())
      model.complete(session, words: 1, recordingSeconds: 1, at: completionDate)
      await model.waitForPendingWrites()
      XCTAssertNotNil(model.storageError)
      XCTAssertEqual(model.data, originalData)
      XCTAssertEqual(try Data(contentsOf: url), originalFile)
    }
  }

  func testCheckedMergeDoesNotPartiallyApplyInvalidTotals() {
    for original in [UsageTotals(words: .max), UsageTotals(dictations: .max),
                     UsageTotals(recordingSeconds: Double(Int64.max).nextDown)] {
      var totals = original
      XCTAssertFalse(totals.add(words: 1, recordingSeconds: Double(Int64.max).nextDown))
      XCTAssertEqual(totals, original)
    }
    var totals = UsageTotals(words: 12, dictations: 2)
    XCTAssertFalse(totals.add(words: -1, recordingSeconds: 1))
    XCTAssertEqual(totals, UsageTotals(words: 12, dictations: 2))
  }

  func testRepresentableDurationBoundaryFormatsAndNonfiniteSpeedIsOmitted() {
    let totals = UsageTotals(recordingSeconds: Double(Int64.max).nextDown)
    XCTAssertTrue(totals.isValid)
    XCTAssertFalse(Duration.seconds(totals.recordingSeconds).formatted(
      .units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2)
    ).isEmpty)
    XCTAssertFalse(UsageTotals(recordingSeconds: Double(Int64.max)).isValid)
    XCTAssertNil(UsageTotals(words: 1, recordingSeconds: .leastNonzeroMagnitude,
                            timedWords: 1).wordsPerMinute)
  }

  func testTerminationDrainsSaveAndClearBeforeReturning() async throws {
    let model = UsageStatsModel(defaults: defaults, url: url)
    let session = try XCTUnwrap(model.begin())
    model.complete(session, words: 10, recordingSeconds: 6, at: Date())
    await model.finishPendingOperationsForTermination()
    XCTAssertNil(model.begin())
    let store = UsageStatsStore(url: url)
    let saved = try await store.load()
    XCTAssertEqual(UsageCalendar.summary(saved, period: .all).totals.words, 10)
    let clearing = UsageStatsModel(defaults: defaults, url: url)
    clearing.clear()
    await clearing.finishPendingOperationsForTermination()
    let cleared = try await store.load()
    XCTAssertTrue(cleared.days.isEmpty)
  }

  func testDateFiltersFillGapsAndWeightAcrossDays() {
    var data = UsageStatsData()
    for (day, words) in [("2026-08-01", 500), ("2026-09-15", 60), ("2026-09-21", 120)] {
      data.days[day, default: UsageTotals()].add(words: words, recordingSeconds: 60)
    }
    let week = UsageCalendar.summary(data, period: .week, now: date("2026-09-21"), timeZone: .gmt)
    XCTAssertEqual(week.totals.words, 180)
    XCTAssertEqual(week.totals.wordsPerMinute, 90)
    XCTAssertEqual(week.points.count, 7)
    XCTAssertEqual(week.points.filter { $0.words == 0 }.count, 5)
    let month = UsageCalendar.summary(data, period: .month, now: date("2026-09-21"), timeZone: .gmt)
    XCTAssertEqual(month.points.count, 30)
    XCTAssertEqual(month.totals.words, 180)
    XCTAssertEqual(UsageCalendar.summary(data, period: .all, now: date("2026-09-21"),
                                        timeZone: .gmt).totals.words, 680)
  }

  func testCivilDatesAndMonthlyAllTime() {
    let instant = ISO8601DateFormatter().date(from: "2026-09-21T00:30:00Z")!
    XCTAssertEqual(UsageCalendar.dayKey(instant, timeZone: TimeZone(secondsFromGMT: -7 * 3600)!),
                   "2026-09-20")
    XCTAssertEqual(UsageCalendar.dayKey(instant, timeZone: .gmt), "2026-09-21")
    var data = UsageStatsData()
    data.days["2026-01-01", default: UsageTotals()].add(words: 10, recordingSeconds: 5)
    data.days["2026-01-31", default: UsageTotals()].add(words: 20, recordingSeconds: 5)
    let summary = UsageCalendar.summary(data, period: .all, now: date("2026-09-21"), timeZone: .gmt)
    XCTAssertEqual(summary.granularity, .monthly)
    XCTAssertEqual(summary.points.count, 9)
    XCTAssertEqual(summary.points.first?.words, 30)
    XCTAssertNil(UsageCalendar.date(for: "2026-02-31"))
  }

  func testAllTimeIncludesFutureUsageAfterClockCorrection() {
    let data = UsageStatsData(days: [
      "2026-09-23": UsageTotals(words: 10, dictations: 1),
      "2030-09-23": UsageTotals(words: 20, dictations: 1)
    ])
    let summary = UsageCalendar.summary(data, period: .all, now: date("2026-09-23"), timeZone: .gmt)
    XCTAssertEqual(summary.granularity, .monthly)
    XCTAssertEqual(summary.points.count, 49)
    XCTAssertEqual(summary.totals.words, 30)
    XCTAssertEqual(summary.points.reduce(0) { $0 + $1.words }, summary.totals.words)
    XCTAssertEqual(summary.points.first?.words, 10)
    XCTAssertEqual(summary.points.last?.words, 20)
    for period in [UsagePeriod.week, .month] {
      let recent = UsageCalendar.summary(data, period: period, now: date("2026-09-23"), timeZone: .gmt)
      XCTAssertEqual(recent.granularity, .daily)
      XCTAssertEqual(recent.points.count, period.dayCount)
      XCTAssertEqual(recent.totals.words, 10)
    }
  }

  func testFutureOnlyUsageUsesFullDisplaySpan() {
    let data = UsageStatsData(days: ["2030-09-23": UsageTotals(words: 20, dictations: 1)])
    let summary = UsageCalendar.summary(data, period: .all, now: date("2026-09-23"), timeZone: .gmt)
    XCTAssertEqual(summary.granularity, .monthly)
    XCTAssertEqual(summary.points.count, 49)
    XCTAssertEqual(summary.points.last?.words, 20)
    XCTAssertEqual(summary.points.reduce(0) { $0 + $1.words }, 20)
  }

  func testAllTimeGranularityBoundaries() {
    for (lastDay, expected, count) in [
      ("2026-03-31", UsageBucketGranularity.daily, 90),
      ("2026-04-01", .monthly, 4),
      ("2035-12-31", .monthly, 120),
      ("2036-01-01", .yearly(yearsPerBucket: 1), 11),
      ("2145-12-31", .yearly(yearsPerBucket: 1), 120),
      ("2146-01-01", .yearly(yearsPerBucket: 2), 61)
    ] {
      let data = UsageStatsData(days: [
        "2026-01-01": UsageTotals(words: 10, dictations: 1),
        lastDay: UsageTotals(words: 20, dictations: 1)
      ])
      let summary = UsageCalendar.summary(data, period: .all, now: date("2026-01-01"), timeZone: .gmt)
      XCTAssertEqual(summary.granularity, expected, lastDay)
      XCTAssertEqual(summary.points.count, count, lastDay)
      XCTAssertEqual(summary.points.reduce(0) { $0 + $1.words }, 30, lastDay)
    }
  }

  func testExtremeAcceptedDatesKeepAllWordsInBoundedBuckets() {
    let data = UsageStatsData(days: [
      "0001-01-01": UsageTotals(words: 10, dictations: 1),
      "2026-09-23": UsageTotals(words: 20, dictations: 1),
      "9999-12-31": UsageTotals(words: 30, dictations: 1),
      "100000-01-01": UsageTotals(words: 40, dictations: 1)
    ])
    XCTAssertTrue(data.isValid)
    let summary = UsageCalendar.summary(data, period: .all, now: date("2026-09-23"), timeZone: .gmt)
    XCTAssertEqual(summary.granularity, .yearly(yearsPerBucket: 834))
    XCTAssertEqual(summary.granularity.caption, "Words per 834 years")
    XCTAssertLessThanOrEqual(summary.points.count, 120)
    XCTAssertEqual(summary.totals.words, 100)
    XCTAssertEqual(summary.points.reduce(0) { $0 + $1.words }, summary.totals.words)
    XCTAssertEqual(summary.points.first?.words, 10)
    XCTAssertEqual(summary.points.last?.words, 40)
    XCTAssertEqual(Set(summary.points.map(\.date)).count, summary.points.count)
  }

  private func date(_ day: String) -> Date {
    // Midday UTC avoids relying on the test machine's local date near midnight.
    UsageCalendar.date(for: day)!.addingTimeInterval(12 * 3600)
  }
}

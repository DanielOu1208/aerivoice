import Foundation
import NaturalLanguage

struct UsageSession: Hashable, Sendable {
  let id = UUID()
  let generation: UUID
}

@MainActor
protocol UsageStatsRecording: AnyObject {
  func begin() -> UsageSession?
  func complete(_ session: UsageSession, words: Int, recordingSeconds: Double, at date: Date)
  func discard(_ session: UsageSession)
}

enum UsageWordCounter {
  static func count(_ text: String) -> Int {
    let tokenizer = NLTokenizer(unit: .word)
    tokenizer.string = text
    var count = 0
    tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
      if text[range].unicodeScalars.contains(where: { CharacterSet.alphanumerics.contains($0) }) {
        count += 1
      }
      return true
    }
    return count
  }
}

struct UsageTotals: Codable, Equatable, Sendable {
  var words = 0
  var dictations = 0
  var recordingSeconds: Double = 0
  var timedWords = 0

  var wordsPerMinute: Double? {
    guard recordingSeconds > 0 else { return nil }
    let speed = Double(timedWords) * 60 / recordingSeconds
    return speed.isFinite ? speed : nil
  }

  @discardableResult
  mutating func add(words: Int, recordingSeconds: Double) -> Bool {
    let hasDuration = recordingSeconds.isFinite && recordingSeconds > 0
    return merge(Self(words: words, dictations: 1,
                      recordingSeconds: hasDuration ? recordingSeconds : 0,
                      timedWords: hasDuration ? words : 0))
  }

  @discardableResult
  mutating func merge(_ other: Self) -> Bool {
    guard isValid, other.isValid else { return false }
    let (words, wordsOverflow) = self.words.addingReportingOverflow(other.words)
    let (dictations, dictationsOverflow) = self.dictations.addingReportingOverflow(other.dictations)
    let (timedWords, timedWordsOverflow) = self.timedWords.addingReportingOverflow(other.timedWords)
    let combined = Self(words: words, dictations: dictations,
                        recordingSeconds: recordingSeconds + other.recordingSeconds,
                        timedWords: timedWords)
    guard !wordsOverflow, !dictationsOverflow, !timedWordsOverflow, combined.isValid else {
      return false
    }
    self = combined
    return true
  }

  var isValid: Bool {
    words >= 0 && dictations >= 0 && timedWords >= 0 && timedWords <= words
      && recordingSeconds.isFinite && recordingSeconds >= 0
      // Keep duration conversion and formatting within representable whole seconds.
      && recordingSeconds < Double(Int64.max)
  }
}

struct UsageStatsData: Codable, Equatable, Sendable {
  var version = 1
  var days: [String: UsageTotals] = [:]

  var isValid: Bool {
    guard version == 1 else { return false }
    var total = UsageTotals()
    return days.allSatisfy { key, value in
      UsageCalendar.date(for: key) != nil && total.merge(value)
    }
  }
}

enum UsagePeriod: String, CaseIterable, Identifiable {
  case week = "7 days", month = "30 days", all = "All time"
  var id: Self { self }
  var dayCount: Int? {
    switch self {
    case .week: 7
    case .month: 30
    case .all: nil
    }
  }
}

struct UsageChartPoint: Identifiable {
  let date: Date
  var words: Int
  var id: Date { date }
}

enum UsageBucketGranularity: Equatable {
  case daily
  case monthly
  case yearly(yearsPerBucket: Int)

  var caption: String {
    switch self {
    case .daily: "Words by day"
    case .monthly: "Words by month"
    case .yearly(let years): years == 1 ? "Words by year" : "Words per \(years) years"
    }
  }
}

struct UsageSummary {
  let totals: UsageTotals
  let points: [UsageChartPoint]
  let granularity: UsageBucketGranularity
  let start: Date
  let end: Date
}

enum UsageCalendar {
  // Persist civil dates, not midnight timestamps: travel must not reassign prior usage.
  static func dayKey(_ date: Date, timeZone: TimeZone = .current) -> String {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let parts = calendar.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
  }

  static var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
  }

  static func date(for key: String) -> Date? {
    let parts = key.split(separator: "-").compactMap { Int($0) }
    guard parts.count == 3,
      let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])),
      dayKey(date, timeZone: calendar.timeZone) == key else { return nil }
    return date
  }

  static func summary(_ data: UsageStatsData, period: UsagePeriod, now: Date = Date(),
                      timeZone: TimeZone = .current) -> UsageSummary {
    let today = date(for: dayKey(now, timeZone: timeZone))!
    let records = data.days.compactMap { key, totals -> (day: Date, totals: UsageTotals)? in
      guard let day = date(for: key) else { return nil }
      return (day, totals)
    }
    let start: Date
    let end: Date
    if let count = period.dayCount {
      start = calendar.date(byAdding: .day, value: 1 - count, to: today)!
      end = today
    } else {
      // Clock corrections and travel can leave saved civil dates after today.
      start = min(today, records.map(\.day).min() ?? today)
      end = max(today, records.map(\.day).max() ?? today)
    }
    let granularity: UsageBucketGranularity
    let component: Calendar.Component
    let step: Int
    let firstBucket: Date
    let pointCount: Int
    let daySpan = calendar.dateComponents([.day], from: start, to: end).day!
    let firstMonth = calendar.dateInterval(of: .month, for: start)!.start
    let lastMonth = calendar.dateInterval(of: .month, for: end)!.start
    let monthCount = calendar.dateComponents([.month], from: firstMonth, to: lastMonth).month! + 1
    if daySpan < 90 {
      granularity = .daily
      component = .day
      step = 1
      firstBucket = start
      pointCount = daySpan + 1
    } else if monthCount <= 120 {
      granularity = .monthly
      component = .month
      step = 1
      firstBucket = firstMonth
      pointCount = monthCount
    } else {
      let yearCount = calendar.component(.year, from: end) - calendar.component(.year, from: start) + 1
      step = (yearCount + 119) / 120
      granularity = .yearly(yearsPerBucket: step)
      component = .year
      firstBucket = calendar.dateInterval(of: .year, for: start)!.start
      pointCount = (yearCount + step - 1) / step
    }

    var totals = UsageTotals()
    var wordsByBucket = Array(repeating: 0, count: pointCount)
    for record in records {
      guard record.day >= start, record.day <= end, totals.merge(record.totals) else { continue }
      let offset = calendar.dateComponents([component], from: firstBucket, to: record.day)
        .value(for: component)!
      // Nonnegative bucket counts cannot exceed the checked running total.
      wordsByBucket[offset / step] += record.totals.words
    }
    let points = wordsByBucket.enumerated().map { index, words in
      UsageChartPoint(date: calendar.date(byAdding: component, value: index * step, to: firstBucket)!,
                      words: words)
    }
    return UsageSummary(totals: totals, points: points, granularity: granularity, start: start, end: end)
  }
}

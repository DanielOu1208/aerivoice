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

struct UsageSummary {
  let totals: UsageTotals
  let points: [UsageChartPoint]
  let monthly: Bool
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
    let start: Date
    if let count = period.dayCount {
      start = calendar.date(byAdding: .day, value: 1 - count, to: today)!
    } else {
      start = data.days.keys.compactMap { date(for: $0) }.min() ?? today
    }
    let monthly = period == .all
      && (calendar.dateComponents([.day], from: start, to: today).day ?? 0) >= 90
    var totals = UsageTotals()
    var buckets: [Date: Int] = [:]
    for (key, value) in data.days {
      guard let day = date(for: key), day >= start,
        period == .all || day <= today else { continue }
      guard totals.merge(value) else { continue }
      let bucket = monthly ? calendar.dateInterval(of: .month, for: day)!.start : day
      // Nonnegative bucket counts cannot exceed the checked running total.
      buckets[bucket, default: 0] += value.words
    }
    var points: [UsageChartPoint] = []
    var cursor = monthly ? calendar.dateInterval(of: .month, for: start)!.start : start
    // Include future civil dates in all-time after traveling west or correcting a clock.
    let end = max(today, buckets.keys.max() ?? today)
    while cursor <= end {
      points.append(UsageChartPoint(date: cursor, words: buckets[cursor, default: 0]))
      cursor = calendar.date(byAdding: monthly ? .month : .day, value: 1, to: cursor)!
    }
    return UsageSummary(totals: totals, points: points, monthly: monthly)
  }
}

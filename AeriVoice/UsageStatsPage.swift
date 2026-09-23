import Charts
import SwiftUI

struct UsageStatsPage: View {
  @ObservedObject var stats: UsageStatsModel
  let openPrivacy: () -> Void
  @State private var period = UsagePeriod.week

  var body: some View {
    TimelineView(.periodic(from: .now, by: 60)) { context in
      let summary = UsageCalendar.summary(stats.data, period: period, now: context.date)
      Form {
        Section {
          VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top, spacing: 16) {
              VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                  Text("Words dictated").foregroundStyle(.secondary)
                  SettingsInfoButton(
                    title: "Usage stats",
                    message: "Words are counted from final output, including text copied to the clipboard. Average WPM is total words divided by recording minutes, including pauses and excluding processing. Cleanup and language affect word counts.")
                }
                Text(stats.isLoaded ? summary.totals.words.formatted() : "—")
                  .font(.system(size: 32, weight: .semibold, design: .rounded))
                  .monospacedDigit()
                  .accessibilityLabel("\(summary.totals.words.formatted()) words dictated")
              }
              Spacer(minLength: 0)
              VStack(alignment: .trailing, spacing: 8) {
                Picker("Period", selection: $period) {
                  ForEach(UsagePeriod.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel("Stats period")
                .frame(width: 220)
                Text(dateRange(summary))
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
            }

            if !stats.isLoaded {
              ProgressView("Loading stats…")
                .frame(maxWidth: .infinity, minHeight: 210)
            } else {
              activityChart(summary)
              Divider()
              HStack(alignment: .top, spacing: 16) {
                metric("Average WPM", value: summary.totals.wordsPerMinute?.formatted(
                  .number.precision(.fractionLength(0))) ?? "—")
                metric("Completed dictations", value: summary.totals.dictations.formatted())
                metric("Recording time", value: recordingTime(summary.totals.recordingSeconds))
              }
            }
          }
          .padding(.vertical, 8)
        }

        Section {
          HStack {
            Label(stats.enabled ? "Stored only on this Mac" : "Collection paused",
                  systemImage: stats.enabled ? "lock" : "pause.circle")
              .foregroundStyle(.secondary)
            Spacer()
            Button("Manage Stats…", action: openPrivacy)
          }
          if let error = stats.storageError {
            Label(error, systemImage: "exclamationmark.triangle")
              .foregroundStyle(.orange)
              .font(.callout)
              .fixedSize(horizontal: false, vertical: true)
          }
        } footer: {
          Text("Stats begin with this version of AeriVoice. No audio or transcript history is saved.")
        }
      }
      .formStyle(.grouped)
      .contentMargins(.top, -8, for: .scrollContent)
    }
  }

  @ViewBuilder private func activityChart(_ summary: UsageSummary) -> some View {
    if summary.totals.dictations == 0 {
      ContentUnavailableView {
        Label("No dictations in this period", systemImage: "chart.bar")
      } description: {
        Text(stats.enabled ? "Complete a dictation to see your usage here."
             : "Turn on usage stats in Privacy & Data to collect new dictations.")
      }
      .frame(minHeight: 210)
    } else {
      let labeledDates = Set(chartTicks(summary.points))
      VStack(alignment: .leading, spacing: 10) {
        Text(summary.monthly ? "Words by month" : "Words by day")
          .font(.caption)
          .foregroundStyle(.secondary)
        Chart(summary.points) { point in
          BarMark(x: .value("Date", UsageCalendar.dayKey(point.date, timeZone: .gmt)),
                  y: .value("Words", point.words), width: .ratio(0.65))
            .foregroundStyle(Color.accentColor)
            .cornerRadius(3)
            .accessibilityLabel(point.date.formatted(
              Date.FormatStyle(date: .abbreviated, time: .omitted,
                               calendar: UsageCalendar.calendar, timeZone: .gmt)))
            .accessibilityValue("\(point.words.formatted()) words")
        }
        .chartXAxis {
          AxisMarks { value in
            if let key = value.as(String.self), labeledDates.contains(key),
              let date = UsageCalendar.date(for: key) {
              AxisValueLabel { Text(axisLabel(date, monthly: summary.monthly)) }
            }
          }
        }
        .chartYAxis {
          AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) {
            AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
              .foregroundStyle(.quaternary)
            AxisValueLabel()
          }
        }
        .id(period)
        .frame(height: 185)
      }
    }
  }

  private func dateRange(_ summary: UsageSummary) -> String {
    guard let first = summary.points.first?.date, let last = summary.points.last?.date else {
      return ""
    }
    let style = Date.IntervalFormatStyle(calendar: UsageCalendar.calendar, timeZone: .gmt)
      .month(.abbreviated).year()
    return (first..<last).formatted(summary.monthly ? style : style.day())
  }

  // Categorical civil dates keep bars and labels aligned regardless of the Mac's time zone.
  private func chartTicks(_ points: [UsageChartPoint]) -> [String] {
    let stride = points.count <= 7 ? 1 : Int(ceil(Double(points.count) / 5))
    return points.enumerated().compactMap { index, point in
      guard index.isMultiple(of: stride) || index == points.count - 1 else { return nil }
      return UsageCalendar.dayKey(point.date, timeZone: .gmt)
    }
  }

  private func axisLabel(_ date: Date, monthly: Bool) -> String {
    var style = Date.FormatStyle()
    style.calendar = UsageCalendar.calendar
    style.timeZone = .gmt
    if period == .week { return date.formatted(style.weekday(.abbreviated)) }
    return date.formatted(monthly ? style.month(.abbreviated).year(.twoDigits)
                          : style.month(.abbreviated).day())
  }

  private func metric(_ title: String, value: String) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title).font(.caption).foregroundStyle(.secondary)
      Text(value).font(.system(.title2, design: .rounded).weight(.medium)).monospacedDigit()
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .combine)
  }

  private func recordingTime(_ seconds: Double) -> String {
    Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes, .seconds],
                                               width: .abbreviated, maximumUnitCount: 2))
  }
}

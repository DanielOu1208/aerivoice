import Foundation
import OSLog

@MainActor
final class PerformanceSignposts {
  enum Interval: String, CaseIterable {
    case initialization, captureStartup, recording, finalization, cleanup, insertion

    var name: StaticString {
      switch self {
      case .initialization: "Initialization"
      case .captureStartup: "Capture startup"
      case .recording: "Recording"
      case .finalization: "Transcription finalization"
      case .cleanup: "Cleanup"
      case .insertion: "Insertion"
      }
    }
  }

  private let signposter = OSSignposter(subsystem: "com.danielou.AeriVoice", category: "Performance")
  private var enabled = false
  private var intervals: [Interval: OSSignpostIntervalState] = [:]
  private var preparationIntervals: [UUID: (Bool, OSSignpostIntervalState)] = [:]

  func setEnabled(_ value: Bool) {
    if !value { endAll() }
    enabled = value
  }

  func begin(_ interval: Interval) {
    guard enabled, signposter.isEnabled, intervals[interval] == nil else { return }
    intervals[interval] = signposter.beginInterval(interval.name, id: signposter.makeSignpostID())
  }

  func end(_ interval: Interval) {
    guard let state = intervals.removeValue(forKey: interval) else { return }
    signposter.endInterval(interval.name, state)
  }

  func beginPreparation(_ id: UUID, network: Bool) {
    guard enabled, signposter.isEnabled else { return }
    let state = signposter.beginInterval(
      network ? "Network prewarming" : "Audio preparation", id: signposter.makeSignpostID())
    preparationIntervals[id] = (network, state)
  }

  func endPreparation(_ id: UUID) {
    guard let (network, state) = preparationIntervals.removeValue(forKey: id) else { return }
    signposter.endInterval(network ? "Network prewarming" : "Audio preparation", state)
  }

  func milestone(_ value: BenchmarkMilestone) {
    switch value {
    case .audioEngineStartRequested: begin(.captureStartup)
    case .captureStarted: end(.captureStartup); begin(.recording)
    case .stopRequested: end(.recording)
    case .sttFinalizeStarted: begin(.finalization)
    case .sttFinalized: end(.finalization)
    case .cleanupStarted: begin(.cleanup)
    case .cleanupFinished: end(.cleanup)
    case .insertionStarted: begin(.insertion)
    case .insertionFinished: end(.insertion)
    default: break
    }
  }

  func endInteraction() {
    for interval in Interval.allCases where interval != .initialization { end(interval) }
  }

  func endAll() {
    for interval in Interval.allCases { end(interval) }
    for id in Array(preparationIntervals.keys) { endPreparation(id) }
  }
}

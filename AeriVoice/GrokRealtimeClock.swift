import Foundation

/// Internal evaluation switch; both modes preserve every captured PCM byte.
enum GrokAudioPacketPolicy: Sendable {
  case captureFrames
  case milliseconds100
}

/// One monotonic clock drives packet deadlines and prepared-session lifetime.
@MainActor
struct GrokRealtimeClock {
  var now: () -> ContinuousClock.Instant
  var sleep: (ContinuousClock.Instant) async throws -> Void

  static var continuous: Self {
    Self(now: { ContinuousClock.now }, sleep: { try await ContinuousClock().sleep(until: $0) })
  }
}

import Foundation

/// The microphone's part of a dictation: when it opens and how it closes.
///
/// `DictationCoordinator` decides what a start, a stop or a failure means for the session.
/// This type holds the one fact those decisions turn on, the microphone's state, and the
/// steps that move it: a start requested at the shortcut press and taken over once the
/// session's checks pass, a stop at the release that keeps the last words, and the engine
/// prepared for the next dictation.
@MainActor
final class DictationCapture {
  private enum State {
    case closed
    /// Requested and not recording yet. `early` is a start requested at the shortcut press,
    /// which `start` takes over. `interrupted` means the input went away during it, before
    /// there was a session to report that to.
    case starting(early: Task<AudioStartReport, Error>?, interrupted: Bool)
    case recording(since: ContinuousClock.Instant)
    /// Released: recording until the block that holds the release arrives.
    case closing(UUID)
  }

  /// A microphone closing at the release.
  struct Closing {
    let requested: ContinuousClock.Instant
    fileprivate let id: UUID
    fileprivate let stop: ReleaseStop
  }

  private let audio: AudioCapturing
  private let benchmark: LatencyBenchmarkRecording
  private var state = State.closed
  private var nextPreparation: Task<Void, Never>?
  /// How long the last recording ran.
  private(set) var recordingSeconds: Double = 0

  init(audio: AudioCapturing, benchmark: LatencyBenchmarkRecording) {
    self.audio = audio
    self.benchmark = benchmark
  }

  /// Requested and not recording yet.
  var isStarting: Bool {
    if case .starting = state { true } else { false }
  }

  /// Recording, including the wait for the block that holds the release.
  var isOpen: Bool {
    switch state {
    case .recording, .closing: true
    case .closed, .starting: false
    }
  }

  /// The microphone was requested at the press and `start` has not taken it over yet.
  var startedEarly: Bool {
    if case .starting(early: .some, _) = state { true } else { false }
  }

  /// Requests the microphone at the shortcut press, before the session's checks. If a check
  /// then fails, `abandonEarlyStart` stops it and what it recorded is never sent.
  func startEarly() {
    benchmark.mark(.audioEngineStartRequested)
    let audio = self.audio
    // Not on the main actor, so a busy main thread can't delay the engine.
    let early = Task.detached(priority: .userInitiated) {
      // A Bluetooth headset would switch to its call profile even if a check then failed.
      try await audio.start(discardingAudioBefore: nil, declinesBluetooth: true)
    }
    state = .starting(early: early, interrupted: false)
  }

  /// Opens the microphone for a session whose checks have passed: takes over the start
  /// requested at the press when there is one, and otherwise starts now.
  func start(discardingAudioBefore deadline: ContinuousClock.Instant?) async throws
    -> AudioStartReport
  {
    recordingSeconds = 0
    guard case .starting(let early?, _) = state else {
      benchmark.mark(.audioEngineStartRequested)
      state = .starting(early: nil, interrupted: false)
      return try await audio.start(discardingAudioBefore: deadline)
    }
    do {
      let report = try await early.value
      // The input may have gone away while the checks kept the main thread busy. Its report
      // is queued behind them; let it run while this start can still fail on it.
      await withCheckedContinuation { continuation in
        DispatchQueue.main.async { continuation.resume() }
      }
      // A cancel or a failure in the meantime closed the microphone, and a later press may
      // already have requested it again.
      guard case .starting(early, let interrupted) = state else { throw CancellationError() }
      // The engine stopped while the checks ran; recording from it would capture nothing.
      guard !interrupted else { throw AppError.microphoneUnavailable }
      state = .starting(early: nil, interrupted: false)
      return report
    } catch is AudioStartDeclined {
      benchmark.mark(.earlyAudioStartDeclined)
      guard case .starting(early, _) = state else { throw CancellationError() }
      state = .starting(early: nil, interrupted: false)
      return try await audio.start(discardingAudioBefore: deadline)
    }
  }

  func beganRecording() {
    state = .recording(since: .now)
  }

  /// The input went away before there was a session to fail. A start requested at the press
  /// remembers it, and fails when the session takes it over.
  func inputLostBeforeSession() {
    guard case .starting(let early?, _) = state else { return }
    state = .starting(early: early, interrupted: true)
  }

  /// A check failed after the microphone started at the press: stops it and prepares the next
  /// engine. Returns whether there was such a start.
  func abandonEarlyStart() -> Bool {
    guard case .starting(let early?, _) = state else { return false }
    early.cancel()
    audio.cancelStart()
    state = .closed
    prepareNext()
    return true
  }

  /// A recording microphone keeps going until its block holding `release` (a host time)
  /// arrives, at most one ~100 ms block, and keeps only what was said before the release, so
  /// the end of the last word isn't lost. Returns nil when it isn't recording.
  func beginClose(atRelease release: UInt64) -> Closing? {
    guard case .recording(let since) = state else { return nil }
    recordDuration(since: since)
    let closing = Closing(
      requested: .now, id: UUID(), stop: audio.beginStop(atHostTime: release))
    state = .closing(closing.id)
    return closing
  }

  /// Returns once the microphone has closed, and whether this release closed it: false when
  /// a cancel or a failure during the wait already had.
  func finishClose(_ closing: Closing) async -> Bool {
    await closing.stop.wait()
    guard case .closing(let id) = state, id == closing.id else { return false }
    state = .closed
    return true
  }

  /// Closes the microphone at once, or cancels a start still in flight. Returns how long
  /// closing a running microphone took.
  @discardableResult
  func stop() -> Duration? {
    switch state {
    case .closed:
      return nil
    case .starting(let early, _):
      // A start requested at the press runs in its own task; cancel it too.
      early?.cancel()
      audio.cancelStart()
      state = .closed
      return nil
    case .recording(let since):
      recordDuration(since: since)
    case .closing:
      break
    }
    state = .closed
    let stopping = ContinuousClock.now
    audio.stop()
    return stopping.duration(to: .now)
  }

  /// Engine preparation does not open the microphone and saves ~40 ms at the next start. The
  /// audio queue runs it after any stop requested before it.
  func prepareNext() {
    let audio = self.audio
    nextPreparation = Task.detached(priority: .utility) { await audio.prepare() }
  }

  /// Releases an engine that is prepared and unused, and one still being prepared.
  func discardPreparation() {
    nextPreparation?.cancel()
    nextPreparation = nil
    audio.discardPreparation()
  }

  private func recordDuration(since started: ContinuousClock.Instant) {
    let duration = started.duration(to: .now).components
    recordingSeconds = Double(duration.seconds) + Double(duration.attoseconds) / 1e18
  }
}

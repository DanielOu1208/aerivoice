@preconcurrency import AVFoundation
import Accelerate
import CoreAudio
import Foundation

final class AudioCaptureService: AudioCapturing, @unchecked Sendable {
  var onAudio: ((Data) -> Void)?
  var onCaptureInterrupted: (() -> Void)?

  /// Device switches arrive as bursts (default change, then format renegotiation).
  static let restartDebounce: DispatchTimeInterval = .milliseconds(150)
  static let maximumRestarts = 3
  /// Longest wait for the block holding the release: one ~100 ms tap block plus headroom.
  static let releaseBlockTimeout: DispatchTimeInterval = .milliseconds(200)

  private let queue = DispatchQueue(label: "com.danielou.AeriVoice.audio", qos: .userInteractive)
  private let makeEngine: @Sendable (AudioInputRoute) -> CaptureAudioEngine
  private let currentRoute: @Sendable () -> AudioInputRoute?
  private let restartDebounce: DispatchTimeInterval
  private let releaseBlockTimeout: DispatchTimeInterval
  private let lifecycleLock = NSLock()
  private var lifecycleGeneration = UUID()
  private var engine: CaptureAudioEngine?
  private var preparedRoute: AudioInputRoute?
  private var activeRoute: AudioInputRoute?
  private var configurationObserver: NSObjectProtocol?
  private var converter: PCM16AudioConverter?
  private var recording = false
  private var captureGeneration = UUID()
  private var restartToken: UUID?
  private var restartCount = 0
  private var samplesToDiscard = 0
  private var pendingRelease: PendingRelease?
  /// Host time just after the last block delivered whole.
  private var lastBlockEnd: UInt64?

  /// A stop waiting for the tap block that holds the release.
  private struct PendingRelease {
    let hostTime: UInt64
    let token: UUID
    let finished: () -> Void
  }

  init(
    makeEngine: @escaping @Sendable (AudioInputRoute) -> CaptureAudioEngine = { route in
      SystemCaptureAudioEngine(deviceID: route.pinned ? route.deviceID : nil)
    },
    currentRoute: @escaping @Sendable () -> AudioInputRoute? = {
      AudioInputRoute.current(preferredDeviceUID: AppPreferences.storedInputDeviceUID())
    },
    restartDebounce: DispatchTimeInterval = AudioCaptureService.restartDebounce,
    releaseBlockTimeout: DispatchTimeInterval = AudioCaptureService.releaseBlockTimeout
  ) {
    self.makeEngine = makeEngine
    self.currentRoute = currentRoute
    self.restartDebounce = restartDebounce
    self.releaseBlockTimeout = releaseBlockTimeout
  }

  deinit {
    if let configurationObserver {
      NotificationCenter.default.removeObserver(configurationObserver)
    }
    engine?.stop()
  }

  func prepare() async {
    _ = await prepareWithDiagnostics()
  }

  func prepareWithDiagnostics() async -> DiagnosticPreparationResult {
    let generation = lifecycleLock.withLock { lifecycleGeneration }
    let request = AudioStartupRequest()
    return await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        queue.async {
          guard self.isCurrent(generation), !request.isCancelled else {
            continuation.resume(returning: .cancelled)
            return
          }
          guard self.engine == nil else {
            continuation.resume(returning: .skipped)
            return
          }
          do {
            try self.prepareOnQueue()
            if !self.isCurrent(generation) || request.isCancelled {
              self.stopOnQueue()
              continuation.resume(returning: .cancelled)
            } else {
              continuation.resume(returning: self.preparedRoute == nil ? .skipped : .prepared)
            }
          } catch {
            self.stopOnQueue()
            continuation.resume(returning: .failed)
          }
        }
      }
    } onCancel: {
      request.cancel()
    }
  }

  /// Releases only unused preparation. Active capture is stopped by stop().
  func discardPreparation() {
    lifecycleLock.withLock { lifecycleGeneration = UUID() }
    queue.async {
      if !self.recording { self.stopOnQueue() }
    }
  }

  func start(
    discardingAudioBefore deadline: ContinuousClock.Instant?, declinesBluetooth: Bool
  ) async throws -> AudioStartReport {
    try Task.checkCancellation()
    let generation = lifecycleLock.withLock { lifecycleGeneration }
    let request = AudioStartupRequest()
    let requested = ContinuousClock.now
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        queue.async {
          do {
            let queueWait = requested.duration(to: .now)
            guard self.isCurrent(generation), !request.isCancelled else {
              throw CancellationError()
            }
            var report = try self.startOnQueue(
              discardingAudioBefore: deadline, declinesBluetooth: declinesBluetooth
            ) {
              guard self.isCurrent(generation), !request.isCancelled else {
                throw CancellationError()
              }
            }
            guard self.isCurrent(generation), !request.isCancelled else {
              self.stopOnQueue()
              throw CancellationError()
            }
            report.queueWait = queueWait
            continuation.resume(returning: report)
          } catch {
            continuation.resume(throwing: error)
          }
        }
      }
    } onCancel: {
      request.cancel()
    }
  }

  func cancelStart() {
    lifecycleLock.withLock { lifecycleGeneration = UUID() }
    queue.async { self.stopOnQueue() }
  }

  /// Delivers audio still held by the converter before capture ends.
  func stop() {
    lifecycleLock.withLock { lifecycleGeneration = UUID() }
    queue.sync { stopOnQueue(flushingConverter: true) }
  }

  /// Ends capture at the release. Tap blocks are ~100 ms and a partly filled one is dropped
  /// when the engine stops, so stopping at once loses the end of a word said right before
  /// release. Instead capture runs until the block holding `hostTime` arrives, keeps only its
  /// frames before the release, then stops. A stalled input stops after `releaseBlockTimeout`;
  /// stop(), an interruption or a new start end the wait at once. The release reaches the
  /// queue before any later block, so call this as soon as the shortcut is released.
  func beginStop(atHostTime hostTime: UInt64) -> ReleaseStop {
    lifecycleLock.withLock { lifecycleGeneration = UUID() }
    let stop = ReleaseStop()
    queue.async {
      // An engine that has stopped delivering has no block left to wait for, and one whose
      // block holding the release has already gone through has nothing left to keep.
      guard self.recording, self.engine?.isRunning == true, self.pendingRelease == nil,
        !(self.lastBlockEnd.map { $0 >= hostTime } ?? false)
      else {
        self.stopOnQueue(flushingConverter: true)
        stop.finish()
        return
      }
      // A restart scheduled just before release would open a microphone only to close it.
      self.restartToken = nil
      let token = UUID()
      self.pendingRelease = PendingRelease(hostTime: hostTime, token: token, finished: stop.finish)
      self.queue.asyncAfter(deadline: .now() + self.releaseBlockTimeout) { [weak self] in
        guard let self, self.pendingRelease?.token == token else { return }
        self.stopOnQueue(flushingConverter: true)
      }
    }
    return stop
  }

  /// Whether a release stop is waiting for its block. For tests.
  var isWaitingForReleaseBlock: Bool { queue.sync { pendingRelease != nil } }

  private func isCurrent(_ generation: UUID) -> Bool {
    lifecycleLock.withLock { lifecycleGeneration == generation }
  }

  private func prepareOnQueue() throws {
    guard let route = currentRoute() else { throw AppError.microphoneUnavailable }
    // Opening a Bluetooth headset's microphone can switch it to a low-quality call profile.
    guard !route.isBluetooth else { return }
    let engine = makeEngine(route)
    self.engine = engine
    try engine.prepare()
    guard currentRoute() == route else {
      stopOnQueue()
      return
    }
    preparedRoute = route
    observeConfigurationChanges(of: engine)
  }

  private func observeConfigurationChanges(of engine: CaptureAudioEngine) {
    if let configurationObserver {
      NotificationCenter.default.removeObserver(configurationObserver)
    }
    configurationObserver = NotificationCenter.default.addObserver(
      forName: .AVAudioEngineConfigurationChange, object: engine.notificationObject, queue: nil
    ) { [weak self, weak engine] _ in
      guard let self, let engine else { return }
      self.queue.async {
        guard self.engine === engine else { return }
        if self.pendingRelease != nil {
          // Capture ends at the release, so it never moves to another input. A stopped engine
          // has no block holding the release left to deliver.
          if !engine.isRunning { self.stopOnQueue(flushingConverter: true) }
        } else if self.recording {
          self.scheduleRestartOnQueue()
        } else {
          self.stopOnQueue()
        }
      }
    }
  }

  private func startOnQueue(
    discardingAudioBefore deadline: ContinuousClock.Instant?, declinesBluetooth: Bool,
    checkCancellation: @Sendable () throws -> Void
  ) throws -> AudioStartReport {
    guard !recording else { return AudioStartReport(usedPreparation: false) }
    let clock = ContinuousClock()
    var step = clock.now
    let current = currentRoute()
    // Declined before anything changes, so a prepared engine stays prepared.
    if declinesBluetooth, current?.isBluetooth != false { throw AudioStartDeclined() }
    if preparedRoute == nil || preparedRoute != current { stopOnQueue() }
    var report = AudioStartReport(usedPreparation: engine != nil)
    report.routeCheck = step.duration(to: clock.now)
    // An unreadable route still attempts the system default; the engine validates its input.
    let route = preparedRoute ?? current
      ?? AudioInputRoute(deviceID: AudioDeviceID(kAudioObjectUnknown), sampleRate: 0, channels: 0)
    step = clock.now
    let engine = self.engine ?? makeEngine(route)
    if !report.usedPreparation { report.engineCreation = step.duration(to: clock.now) }
    self.engine = engine
    preparedRoute = nil
    activeRoute = route
    restartCount = 0
    guard let converter = PCM16AudioConverter() else {
      stopOnQueue()
      throw AppError.microphoneUnavailable
    }
    self.converter = converter
    do {
      report.engine = try startCapture(engine, checkCancellation: checkCancellation)
      if configurationObserver == nil { observeConfigurationChanges(of: engine) }
      recording = true
      let started = ContinuousClock.now
      // Capture begins about when start returns; drop samples recorded before the deadline.
      let discarded = deadline.map { started.duration(to: $0) / .seconds(1) } ?? 0
      samplesToDiscard = Int(max(0, discarded) * PCM16AudioConverter.sampleRate)
      return report
    } catch {
      stopOnQueue()
      throw error
    }
  }

  @discardableResult
  private func startCapture(
    _ engine: CaptureAudioEngine, checkCancellation: @Sendable () throws -> Void
  ) throws -> CaptureEngineStartSteps {
    let generation = UUID()
    captureGeneration = generation
    return try engine.start(checkCancellation: checkCancellation) { [weak self] buffer, hostTime in
      guard let service = self else { return }
      service.queue.async { service.convert(buffer, hostTime: hostTime, generation: generation) }
    }
  }

  private func scheduleRestartOnQueue() {
    let token = UUID()
    restartToken = token
    queue.asyncAfter(deadline: .now() + restartDebounce) { [weak self] in
      guard let self, self.restartToken == token, self.recording else { return }
      self.restartToken = nil
      self.restartOnQueue()
    }
  }

  /// Rebuilds capture on the current input while the transcription session stays open.
  private func restartOnQueue() {
    guard let engine else { return }
    let route = currentRoute()
    if engine.isRunning, route == activeRoute { return }
    guard restartCount < Self.maximumRestarts, let route else {
      interruptOnQueue()
      return
    }
    restartCount += 1
    engine.stop()
    let replacement = makeEngine(route)
    self.engine = replacement
    activeRoute = route
    observeConfigurationChanges(of: replacement)
    do {
      try startCapture(replacement, checkCancellation: {})
    } catch {
      interruptOnQueue()
    }
  }

  private func interruptOnQueue() {
    stopOnQueue()
    onCaptureInterrupted?()
  }

  private func stopOnQueue(flushingConverter: Bool = false) {
    captureGeneration = UUID()
    restartToken = nil
    if let configurationObserver {
      NotificationCenter.default.removeObserver(configurationObserver)
      self.configurationObserver = nil
    }
    engine?.stop()
    if flushingConverter, recording, let data = converter?.flush() { deliver(data) }
    engine = nil
    preparedRoute = nil
    activeRoute = nil
    converter = nil
    recording = false
    samplesToDiscard = 0
    lastBlockEnd = nil
    if let pendingRelease {
      self.pendingRelease = nil
      pendingRelease.finished()
    }
  }

  private func convert(_ input: AVAudioPCMBuffer, hostTime: UInt64?, generation: UUID) {
    guard captureGeneration == generation, recording, let converter else { return }
    guard let release = pendingRelease?.hostTime else {
      if let data = converter.convert(input) { deliver(data) }
      lastBlockEnd = hostTime.map {
        $0 + AVAudioTime.hostTime(forSeconds: Double(input.frameLength) / input.format.sampleRate)
      }
      return
    }
    let cut = CaptureRelease.cut(
      release: release, blockStart: hostTime, frames: input.frameLength,
      sampleRate: input.format.sampleRate)
    let kept = cut.keep == input.frameLength ? input : input.prefix(cut.keep)
    if cut.keep > 0, let kept, let data = converter.convert(kept) { deliver(data) }
    if cut.reachesRelease { stopOnQueue(flushingConverter: true) }
  }

  private func deliver(_ data: Data) {
    guard samplesToDiscard > 0 else {
      onAudio?(data)
      return
    }
    let samples = data.count / MemoryLayout<Int16>.size
    let dropped = min(samples, samplesToDiscard)
    samplesToDiscard -= dropped
    guard dropped < samples else { return }
    onAudio?(Data(data.dropFirst(dropped * MemoryLayout<Int16>.size)))
  }
}

/// Where the release falls within a tap block. Pure, so the arithmetic is testable.
enum CaptureRelease {
  /// How many of the block's frames came before the release, and whether the block reaches
  /// it (so capture can stop). A block with no known start time is kept whole and ends capture.
  static func cut(
    release: UInt64, blockStart: UInt64?, frames: AVAudioFrameCount, sampleRate: Double
  ) -> (keep: AVAudioFrameCount, reachesRelease: Bool) {
    guard let blockStart, sampleRate > 0 else { return (frames, true) }
    let seconds = AVAudioTime.seconds(forHostTime: release)
      - AVAudioTime.seconds(forHostTime: blockStart)
    let before = (seconds * sampleRate).rounded(.down)
    guard before > 0 else { return (0, true) }
    guard before < Double(frames) else { return (frames, before == Double(frames)) }
    return (AVAudioFrameCount(before), true)
  }
}

extension AVAudioPCMBuffer {
  /// A copy of the first `frames` frames, in the same format.
  func prefix(_ frames: AVAudioFrameCount) -> AVAudioPCMBuffer? {
    let count = min(frames, frameLength)
    guard let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: max(count, 1)) else {
      return nil
    }
    let bytesPerFrame = Int(format.streamDescription.pointee.mBytesPerFrame)
    let source = UnsafeMutableAudioBufferListPointer(mutableAudioBufferList)
    let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
    for (from, to) in zip(source, destination) {
      guard let fromData = from.mData, let toData = to.mData else { return nil }
      toData.copyMemory(from: fromData, byteCount: Int(count) * bytesPerFrame)
    }
    copy.frameLength = count
    return copy
  }
}

private final class AudioStartupRequest: @unchecked Sendable {
  private let lock = NSLock()
  private var cancelled = false

  var isCancelled: Bool { lock.withLock { cancelled } }
  func cancel() { lock.withLock { cancelled = true } }
}

/// Mixes to mono, resamples to 16 kHz, removes low-frequency rumble, and emits PCM16.
final class PCM16AudioConverter {
  static let sampleRate = 16_000.0
  /// Below the lowest speaking voices; removes fan hum, desk bumps, and DC offset.
  static let highPassCutoff = 80.0

  private let outputFormat: AVAudioFormat
  private var converter: AVAudioConverter?
  // Stored non-optionally: copying a Biquad out of an optional and back resets its state.
  private var highPass: vDSP.Biquad<Float>

  init?() {
    guard
      let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: Self.sampleRate, channels: 1,
        interleaved: false),
      let highPass = vDSP.Biquad(
        coefficients: Self.highPassCoefficients(), channelCount: 1, sectionCount: 1,
        ofType: Float.self)
    else { return nil }
    self.outputFormat = outputFormat
    self.highPass = highPass
  }

  func convert(_ input: AVAudioPCMBuffer) -> Data? {
    guard input.format.sampleRate > 0, input.format.channelCount > 0 else { return nil }
    if converter?.inputFormat.isEqual(input.format) != true {
      converter = AVAudioConverter(from: input.format, to: outputFormat)
      // Without downmix the converter keeps only channel 0 of multichannel inputs.
      converter?.downmix = true
    }
    guard let converter else { return nil }

    let ratio = outputFormat.sampleRate / input.format.sampleRate
    let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * ratio)) + 16
    let inputState = ConversionInputState()
    return run(converter, capacity: capacity) { state in
      if inputState.supplied {
        state.pointee = .noDataNow
        return nil
      }
      inputState.supplied = true
      state.pointee = .haveData
      return input
    }
  }

  /// Returns the resampler's remaining samples; the converter cannot be reused afterwards.
  func flush() -> Data? {
    guard let converter else { return nil }
    defer { self.converter = nil }
    return run(converter, capacity: 1_024) { state in
      state.pointee = .endOfStream
      return nil
    }
  }

  private func run(
    _ converter: AVAudioConverter, capacity: AVAudioFrameCount,
    input: @escaping (UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer?
  ) -> Data? {
    guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
      return nil
    }
    var conversionError: NSError?
    let status = converter.convert(to: output, error: &conversionError) { _, state in
      input(state)
    }
    guard status != .error, output.frameLength > 0, let channel = output.floatChannelData?[0]
    else { return nil }
    var samples = Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    samples = highPass.apply(input: samples)
    samples = vDSP.clip(
      vDSP.multiply(Float(Int16.max), samples), to: Float(Int16.min)...Float(Int16.max))
    let pcm = vDSP.floatingPointToInteger(
      samples, integerType: Int16.self, rounding: .towardNearestInteger)
    return pcm.withUnsafeBufferPointer { Data(buffer: $0) }
  }

  /// Second-order Butterworth high-pass (RBJ cookbook), normalized for vDSP.
  static func highPassCoefficients() -> [Double] {
    let omega = 2 * Double.pi * highPassCutoff / sampleRate
    let cosine = cos(omega)
    let alpha = sin(omega) / (2 * 0.5.squareRoot())
    let a0 = 1 + alpha
    let b0 = (1 + cosine) / 2 / a0
    return [b0, -2 * b0, b0, -2 * cosine / a0, (1 - alpha) / a0]
  }
}

private final class ConversionInputState: @unchecked Sendable {
  var supplied = false
}

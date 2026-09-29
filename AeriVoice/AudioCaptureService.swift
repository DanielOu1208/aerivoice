@preconcurrency import AVFoundation
import Accelerate
import Foundation

final class AudioCaptureService: AudioCapturing, @unchecked Sendable {
  var onAudio: ((Data) -> Void)?
  var onCaptureInterrupted: (() -> Void)?

  /// Device switches arrive as bursts (default change, then format renegotiation).
  static let restartDebounce: DispatchTimeInterval = .milliseconds(150)
  static let maximumRestarts = 3

  private let queue = DispatchQueue(label: "com.danielou.AeriVoice.audio", qos: .userInteractive)
  private let makeEngine: @Sendable (AudioInputRoute) -> CaptureAudioEngine
  private let currentRoute: @Sendable () -> AudioInputRoute?
  private let restartDebounce: DispatchTimeInterval
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

  init(
    makeEngine: @escaping @Sendable (AudioInputRoute) -> CaptureAudioEngine = { route in
      SystemCaptureAudioEngine(deviceID: route.pinned ? route.deviceID : nil)
    },
    currentRoute: @escaping @Sendable () -> AudioInputRoute? = {
      AudioInputRoute.current(preferredDeviceUID: AppPreferences.storedInputDeviceUID())
    },
    restartDebounce: DispatchTimeInterval = AudioCaptureService.restartDebounce
  ) {
    self.makeEngine = makeEngine
    self.currentRoute = currentRoute
    self.restartDebounce = restartDebounce
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

  func start(discardingAudioBefore deadline: ContinuousClock.Instant?) async throws -> Bool {
    try Task.checkCancellation()
    let generation = lifecycleLock.withLock { lifecycleGeneration }
    let request = AudioStartupRequest()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        queue.async {
          do {
            guard self.isCurrent(generation), !request.isCancelled else {
              throw CancellationError()
            }
            let usedPreparation = try self.startOnQueue(discardingAudioBefore: deadline) {
              guard self.isCurrent(generation), !request.isCancelled else {
                throw CancellationError()
              }
            }
            guard self.isCurrent(generation), !request.isCancelled else {
              self.stopOnQueue()
              throw CancellationError()
            }
            continuation.resume(returning: usedPreparation)
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
        if self.recording {
          self.scheduleRestartOnQueue()
        } else {
          self.stopOnQueue()
        }
      }
    }
  }

  private func startOnQueue(
    discardingAudioBefore deadline: ContinuousClock.Instant?,
    checkCancellation: @Sendable () throws -> Void
  ) throws -> Bool {
    guard !recording else { return false }
    let route = currentRoute()
    if preparedRoute == nil || preparedRoute != route { stopOnQueue() }
    let usedPreparation = engine != nil
    guard let route = preparedRoute ?? route else {
      stopOnQueue()
      throw AppError.microphoneUnavailable
    }
    let engine = self.engine ?? makeEngine(route)
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
      try startCapture(engine, checkCancellation: checkCancellation)
      if configurationObserver == nil { observeConfigurationChanges(of: engine) }
      recording = true
      let started = ContinuousClock.now
      // Capture begins about when start returns; drop samples recorded before the deadline.
      let discarded = deadline.map { started.duration(to: $0) / .seconds(1) } ?? 0
      samplesToDiscard = Int(max(0, discarded) * PCM16AudioConverter.sampleRate)
      return usedPreparation
    } catch {
      stopOnQueue()
      throw error
    }
  }

  private func startCapture(
    _ engine: CaptureAudioEngine, checkCancellation: @Sendable () throws -> Void
  ) throws {
    let generation = UUID()
    captureGeneration = generation
    try engine.start(checkCancellation: checkCancellation) { [weak self] buffer in
      guard let service = self else { return }
      service.queue.async { service.convert(buffer, generation: generation) }
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
  }

  private func convert(_ input: AVAudioPCMBuffer, generation: UUID) {
    guard captureGeneration == generation, recording, let converter else { return }
    guard let data = converter.convert(input) else { return }
    deliver(data)
  }

  private func deliver(_ data: Data) {
    var data = data
    if samplesToDiscard > 0 {
      let samples = data.count / MemoryLayout<Int16>.size
      let dropped = min(samples, samplesToDiscard)
      samplesToDiscard -= dropped
      data = data.dropFirst(dropped * MemoryLayout<Int16>.size)
    }
    guard !data.isEmpty else { return }
    onAudio?(Data(data))
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

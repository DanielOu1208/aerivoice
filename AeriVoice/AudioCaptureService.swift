@preconcurrency import AVFoundation
import Foundation

final class AudioCaptureService: AudioCapturing, @unchecked Sendable {
  var onAudio: ((Data) -> Void)?

  private let queue = DispatchQueue(label: "com.danielou.AeriVoice.audio", qos: .userInteractive)
  private let makeEngine: @Sendable () -> CaptureAudioEngine
  private let currentRoute: @Sendable () -> AudioInputRoute?
  private let lifecycleLock = NSLock()
  private var lifecycleGeneration = UUID()
  private var engine: CaptureAudioEngine?
  private var preparedRoute: AudioInputRoute?
  private var configurationObserver: NSObjectProtocol?
  private var converter: PCM16AudioConverter?
  private var recording = false
  private var captureGeneration = UUID()

  init(
    makeEngine: @escaping @Sendable () -> CaptureAudioEngine = { SystemCaptureAudioEngine() },
    currentRoute: @escaping @Sendable () -> AudioInputRoute? = { AudioInputRoute.current() }
  ) {
    self.makeEngine = makeEngine
    self.currentRoute = currentRoute
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

  func start() async throws -> Bool {
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
            let usedPreparation = try self.startOnQueue {
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

  func stop() {
    lifecycleLock.withLock { lifecycleGeneration = UUID() }
    queue.sync { stopOnQueue() }
  }

  private func isCurrent(_ generation: UUID) -> Bool {
    lifecycleLock.withLock { lifecycleGeneration == generation }
  }

  private func prepareOnQueue() throws {
    guard let route = currentRoute() else { throw AppError.microphoneUnavailable }
    let engine = makeEngine()
    self.engine = engine
    try engine.prepare()
    guard currentRoute() == route else {
      stopOnQueue()
      return
    }
    preparedRoute = route
    configurationObserver = NotificationCenter.default.addObserver(
      forName: .AVAudioEngineConfigurationChange, object: engine.notificationObject, queue: nil
    ) { [weak self, weak engine] _ in
      guard let self, let engine else { return }
      self.queue.async {
        guard self.engine === engine, !self.recording else { return }
        self.stopOnQueue()
      }
    }
  }

  private func startOnQueue(checkCancellation: @Sendable () throws -> Void) throws -> Bool {
    guard !recording else { return false }
    if preparedRoute == nil || preparedRoute != currentRoute() { stopOnQueue() }
    let usedPreparation = engine != nil
    let engine = self.engine ?? makeEngine()
    self.engine = engine
    preparedRoute = nil
    guard let converter = PCM16AudioConverter() else {
      stopOnQueue()
      throw AppError.microphoneUnavailable
    }
    self.converter = converter
    let generation = UUID()
    captureGeneration = generation
    do {
      try engine.start(checkCancellation: checkCancellation) { [weak self] buffer in
        guard let service = self else { return }
        service.queue.async { service.convert(buffer, generation: generation) }
      }
      recording = true
      return usedPreparation
    } catch {
      stopOnQueue()
      throw error
    }
  }

  private func stopOnQueue() {
    captureGeneration = UUID()
    if let configurationObserver {
      NotificationCenter.default.removeObserver(configurationObserver)
      self.configurationObserver = nil
    }
    engine?.stop()
    engine = nil
    preparedRoute = nil
    converter = nil
    recording = false
  }

  private func convert(_ input: AVAudioPCMBuffer, generation: UUID) {
    guard captureGeneration == generation, recording, let converter else { return }
    guard let data = converter.convert(input) else { return }
    onAudio?(data)
  }
}

private final class AudioStartupRequest: @unchecked Sendable {
  private let lock = NSLock()
  private var cancelled = false

  var isCancelled: Bool { lock.withLock { cancelled } }
  func cancel() { lock.withLock { cancelled = true } }
}

final class PCM16AudioConverter {
  private let outputFormat: AVAudioFormat
  private var converter: AVAudioConverter?

  init?() {
    guard
      let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)
    else { return nil }
    self.outputFormat = outputFormat
  }

  func convert(_ input: AVAudioPCMBuffer) -> Data? {
    guard input.format.sampleRate > 0, input.format.channelCount > 0 else { return nil }
    if converter?.inputFormat.isEqual(input.format) != true {
      converter = AVAudioConverter(from: input.format, to: outputFormat)
    }
    guard let converter else { return nil }

    let ratio = outputFormat.sampleRate / input.format.sampleRate
    let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * ratio)) + 16
    guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
      return nil
    }
    let inputState = ConversionInputState()
    var conversionError: NSError?
    let status = converter.convert(to: output, error: &conversionError) { _, state in
      if inputState.supplied {
        state.pointee = .noDataNow
        return nil
      }
      inputState.supplied = true
      state.pointee = .haveData
      return input
    }
    guard status != .error, output.frameLength > 0,
      let audio = output.audioBufferList.pointee.mBuffers.mData
    else { return nil }
    let byteCount = Int(output.frameLength) * MemoryLayout<Int16>.size
    return Data(bytes: audio, count: byteCount)
  }
}

private final class ConversionInputState: @unchecked Sendable {
  var supplied = false
}

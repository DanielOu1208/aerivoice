@preconcurrency import AVFoundation
import CryptoKit
import Foundation

/// Buffers are filled once before measurement and never mutated after publication.
final class EvalAudioFixture: @unchecked Sendable {
  let buffers: [AVAudioPCMBuffer]
  let rate: Double
  let channels: Int
  let frames: Int
  let hash: String
  var durationMS: Double { Double(frames) / rate * 1_000 }
  var pcmBytes: Int { frames * channels * MemoryLayout<Float>.size }

  init(path: String, rate: Double, channels: Int, chunkFrames: Int) throws {
    let url = URL(fileURLWithPath: path)
    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    guard size > 0, size <= 100_000_000 else { throw EvalError.invalidAudio }
    hash = SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    let file = try AVAudioFile(forReading: url)
    guard file.length > 0, file.processingFormat.sampleRate > 0,
      Double(file.length) / file.processingFormat.sampleRate <= 600,
      let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
      let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
                                 channels: AVAudioChannelCount(channels), interleaved: false),
      let converter = AVAudioConverter(from: file.processingFormat, to: format)
    else { throw EvalError.invalidAudio }
    try file.read(into: input)
    let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * rate / file.processingFormat.sampleRate)) + 1_024
    guard let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { throw EvalError.invalidAudio }
    let inputState = EvalConversionInput()
    var error: NSError?
    let status = converter.convert(to: converted, error: &error) { _, inputStatus in
      if !inputState.take() { inputStatus.pointee = .endOfStream; return nil }
      inputStatus.pointee = .haveData
      return input
    }
    guard status != .error, error == nil, converted.frameLength > 0,
      let source = converted.floatChannelData else { throw EvalError.invalidAudio }
    self.frames = Int(converted.frameLength)
    self.rate = rate
    self.channels = channels
    var chunks: [AVAudioPCMBuffer] = []
    for offset in stride(from: 0, to: frames, by: chunkFrames) {
      let count = min(chunkFrames, frames - offset)
      guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
        let destination = buffer.floatChannelData else { throw EvalError.invalidAudio }
      buffer.frameLength = AVAudioFrameCount(count)
      for channel in 0..<channels { destination[channel].update(from: source[channel] + offset, count: count) }
      chunks.append(buffer)
    }
    buffers = chunks
  }
}

private final class EvalConversionInput: @unchecked Sendable {
  private let lock = NSLock()
  private var supplied = false
  func take() -> Bool {
    lock.withLock {
      guard !supplied else { return false }
      supplied = true
      return true
    }
  }
}

final class EvalCaptureEngine: CaptureAudioEngine, @unchecked Sendable {
  private let fixture: EvalAudioFixture
  private let events: EvalEvents
  private let lock = NSLock()
  private var feeder: Task<Void, Never>?
  private var complete = false
  private var generation = UUID()
  private var emittedFrames = 0
  private var lateFrames = 0
  private var maxLatenessMS = 0.0
  var notificationObject: AnyObject { self }
  var finished: Bool { lock.withLock { complete } }
  var feedSummary: [String: Any] {
    lock.withLock { ["expected_frames": fixture.frames, "emitted_frames": emittedFrames,
                     "late_chunks": lateFrames, "max_lateness_ms": maxLatenessMS,
                     "finished": complete] }
  }

  init(fixture: EvalAudioFixture, events: EvalEvents) { self.fixture = fixture; self.events = events }
  func resetForSession() {
    lock.withLock { complete = false; emittedFrames = 0; lateFrames = 0; maxLatenessMS = 0 }
  }
  func prepare() throws { events.emit("engine_prepared", ["hardware": false]) }

  func start(checkCancellation: @Sendable () throws -> Void,
             onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws {
    try checkCancellation()
    let token = UUID()
    lock.withLock {
      generation = token; complete = false; emittedFrames = 0; lateFrames = 0; maxLatenessMS = 0
    }
    let fixture = fixture
    let events = events
    let origin = events.elapsedMS
    let session = events.session
    events.emit("audio_feed_started", ["duration_ms": fixture.durationMS], at: origin, session: session)
    let task = Task.detached(priority: .userInitiated) { [weak self] in
      let clock = ContinuousClock()
      let start = clock.now
      var frameOffset = 0
      for buffer in fixture.buffers {
        frameOffset += Int(buffer.frameLength)
        let scheduledMS = Double(frameOffset) / fixture.rate * 1_000
        do { try await clock.sleep(until: start.advanced(by: .milliseconds(scheduledMS))) }
        catch { return }
        guard let self else { return }
        let actualMS = events.elapsedMS - origin
        let valid = self.lock.withLock {
          guard self.generation == token else { return false }
          self.emittedFrames += Int(buffer.frameLength)
          self.maxLatenessMS = max(self.maxLatenessMS, actualMS - scheduledMS)
          if actualMS - scheduledMS > Double(buffer.frameLength) / fixture.rate * 1_000 { self.lateFrames += 1 }
          return true
        }
        guard valid, !Task.isCancelled else { return }
        onBuffer(buffer)
      }
      guard let self else { return }
      let valid = self.lock.withLock {
        guard self.generation == token else { return false }
        self.complete = true
        return true
      }
      if valid { events.emit("audio_feed_finished", self.feedSummary, session: session) }
    }
    lock.withLock { feeder = task }
  }

  func stop() {
    let task = lock.withLock {
      generation = UUID()
      let task = feeder
      feeder = nil
      return task
    }
    task?.cancel()
  }
}

@preconcurrency import AVFoundation
import Foundation

final class AudioCaptureService: AudioCapturing, @unchecked Sendable {
  var onAudio: ((Data) -> Void)?

  private let engine = AVAudioEngine()
  private let queue = DispatchQueue(label: "com.danielou.AeriVoice.audio", qos: .userInteractive)
  private var converter: AVAudioConverter?
  private var tapInstalled = false
  private var captureGeneration = UUID()

  func start() throws {
    try queue.sync { try startOnQueue() }
  }

  func stop() {
    queue.sync { stopOnQueue() }
  }

  private func startOnQueue() throws {
    guard !engine.isRunning else { return }
    let input = engine.inputNode
    let source = input.outputFormat(forBus: 0)
    guard source.sampleRate > 0,
      let destination = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true),
      let converter = AVAudioConverter(from: source, to: destination)
    else {
      throw AppError.microphoneUnavailable
    }
    self.converter = converter
    let generation = UUID()
    captureGeneration = generation
    input.installTap(onBus: 0, bufferSize: 1024, format: source) { [weak self] buffer, _ in
      guard let service = self else { return }
      service.queue.async { service.convert(buffer, to: destination, generation: generation) }
    }
    tapInstalled = true
    engine.prepare()
    do {
      try engine.start()
    } catch {
      stopOnQueue()
      throw error
    }
  }

  private func stopOnQueue() {
    captureGeneration = UUID()
    if tapInstalled {
      engine.inputNode.removeTap(onBus: 0)
      tapInstalled = false
    }
    if engine.isRunning { engine.stop() }
    converter = nil
  }

  private func convert(
    _ input: AVAudioPCMBuffer, to format: AVAudioFormat, generation: UUID
  ) {
    guard captureGeneration == generation, let converter else { return }
    let ratio = format.sampleRate / input.format.sampleRate
    let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * ratio)) + 16
    guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
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
    else { return }
    let byteCount = Int(output.frameLength) * MemoryLayout<Int16>.size
    let data = Data(bytes: audio, count: byteCount)
    onAudio?(data)
  }
}

private final class ConversionInputState: @unchecked Sendable {
  var supplied = false
}

@preconcurrency import AVFoundation
import Foundation

final class AudioCaptureService: AudioCapturing, @unchecked Sendable {
  var onAudio: ((Data) -> Void)?

  private let queue = DispatchQueue(label: "com.danielou.AeriVoice.audio", qos: .userInteractive)
  private var engine: AVAudioEngine?
  private var converter: PCM16AudioConverter?
  private var tapInstalled = false
  private var captureGeneration = UUID()

  func start() throws {
    try queue.sync { try startOnQueue() }
  }

  func stop() {
    queue.sync { stopOnQueue() }
  }

  private func startOnQueue() throws {
    guard engine == nil else { return }
    let engine = AVAudioEngine()
    let input = engine.inputNode
    let hardwareFormat = input.inputFormat(forBus: 0)
    guard hardwareFormat.sampleRate > 0, hardwareFormat.channelCount > 0,
      let converter = PCM16AudioConverter()
    else {
      throw AppError.microphoneUnavailable
    }
    self.engine = engine
    self.converter = converter
    let generation = UUID()
    captureGeneration = generation
    input.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
      guard let service = self else { return }
      service.queue.async { service.convert(buffer, generation: generation) }
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
    if tapInstalled, let engine {
      engine.inputNode.removeTap(onBus: 0)
      tapInstalled = false
    }
    if let engine, engine.isRunning { engine.stop() }
    engine = nil
    converter = nil
  }

  private func convert(_ input: AVAudioPCMBuffer, generation: UUID) {
    guard captureGeneration == generation, let converter else { return }
    guard let data = converter.convert(input) else { return }
    onAudio?(data)
  }
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

import AVFoundation
import CoreMedia
import Foundation
import Speech

/// AVAudioConverter invokes this callback synchronously. The buffer is immutable
/// while conversion runs, and the one-shot flag is protected for callback safety.
private final class AppleConverterInput: @unchecked Sendable {
  private let buffer: AVAudioPCMBuffer?
  private let lock = NSLock()
  private var supplied = false

  init(_ buffer: AVAudioPCMBuffer?) { self.buffer = buffer }

  func next(_ state: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
    lock.lock()
    defer { lock.unlock() }
    if let buffer, !supplied {
      supplied = true
      state.pointee = .haveData
      return buffer
    }
    state.pointee = buffer == nil ? .endOfStream : .noDataNow
    return nil
  }
}

/// Apple revisions replace the text covering the same audio interval.
struct AppleTranscriptAccumulator {
  struct Segment {
    let start: Double
    let end: Double
    let text: String
    let isFinal: Bool
  }
  private(set) var segments: [Segment] = []

  mutating func update(start: Double, end: Double, text: String, isFinal: Bool) {
    guard start.isFinite, end.isFinite, end >= start else { return }
    segments.removeAll { ($0.start < end && start < $0.end) || ($0.start == start && $0.end == end) }
    segments.append(Segment(start: start, end: end, text: text, isFinal: isFinal))
    segments.sort { $0.start < $1.start }
  }

  var snapshot: TranscriptSnapshot {
    let confirmed = segments.filter(\.isFinal).map(\.text).joined()
    let provisional = segments.filter { !$0.isFinal }.map(\.text).joined()
    return TranscriptSnapshot(confirmed: confirmed, provisional: provisional)
  }
  var text: String { segments.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines) }
}

@MainActor
final class AppleRealtimeClient: RealtimeTranscribing {
  var onTranscript: ((RealtimeTranscriptUpdate) -> Void)?
  var onError: ((Error) -> Void)?
  private let controller: AppleSpeechController
  private var generation = UUID()
  private var session: Session?

  private final class Session {
    let analyzer: SpeechAnalyzer
    let input: AppleAudioChannel<AnalyzerInput>
    let converter: AVAudioConverter
    let sourceFormat: AVAudioFormat
    let format: AVAudioFormat
    var results: Task<Void, Error>?
    var transcript = AppleTranscriptAccumulator()
    var failure: Error?
    var finishing = false

    init(analyzer: SpeechAnalyzer, input: AppleAudioChannel<AnalyzerInput>,
         converter: AVAudioConverter, sourceFormat: AVAudioFormat, format: AVAudioFormat) {
      self.analyzer = analyzer
      self.input = input
      self.converter = converter
      self.sourceFormat = sourceFormat
      self.format = format
    }
  }

  init(controller: AppleSpeechController = .shared) { self.controller = controller }

  func connect(configuration: TranscriptionConfiguration, apiKey: String,
               vocabulary: [String], sessionID: DictationSessionID) async throws {
    cancel()
    let id = generation
    controller.select(true, localeIdentifier: configuration.appleLocaleIdentifier)
    await controller.waitForPreparation()
    guard generation == id, !Task.isCancelled else { throw CancellationError() }
    guard controller.isReady else {
      throw AppError.provider("Choose a supported language and download its Apple Speech assets in Settings.")
    }
    let transcriber = SpeechTranscriber(locale: Locale(identifier: controller.localeIdentifier),
                                       preset: .progressiveTranscription)
    guard let source = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                    channels: 1, interleaved: false),
          let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber], considering: source),
          let converter = AVAudioConverter(from: source, to: format) else {
      throw AppError.provider("Apple Speech has no compatible audio format.")
    }
    guard generation == id, !Task.isCancelled else { throw CancellationError() }
    let analyzer = SpeechAnalyzer(modules: [transcriber])
    let input = AppleAudioChannel<AnalyzerInput>()
    let current = Session(analyzer: analyzer, input: input,
                          converter: converter, sourceFormat: source, format: format)
    session = current
    current.results = Task { @MainActor [weak self, weak current] in
      do {
        for try await result in transcriber.results {
          guard let self, let current, self.generation == id, !Task.isCancelled else { return }
          current.transcript.update(start: result.range.start.seconds,
                                    end: CMTimeRangeGetEnd(result.range).seconds,
                                    text: String(result.text.characters), isFinal: result.isFinal)
          self.onTranscript?(RealtimeTranscriptUpdate(snapshot: current.transcript.snapshot,
            hasFinalText: result.isFinal, finalAudioProcessedMS: nil, totalAudioProcessedMS: nil))
        }
      } catch {
        if let self, let current, self.generation == id, !Task.isCancelled {
          current.failure = error
          current.input.cancel()
          self.onError?(error)
        }
        throw error
      }
    }
    do {
      let context = AnalysisContext()
      context.contextualStrings[.general] = vocabulary
      try await analyzer.setContext(context)
      guard generation == id, !Task.isCancelled else { throw CancellationError() }
      try await analyzer.prepareToAnalyze(in: format)
      guard generation == id, !Task.isCancelled else { throw CancellationError() }
      try await analyzer.start(inputSequence: input)
      guard generation == id, !Task.isCancelled else { throw CancellationError() }
    } catch {
      input.cancel()
      current.results?.cancel()
      await analyzer.cancelAndFinishNow()
      if generation == id { session = nil }
      throw error
    }
  }

  func send(_ frame: RealtimeAudioFrame) async throws {
    guard let current = session, !current.finishing else { throw CancellationError() }
    let id = generation
    if let failure = current.failure { throw failure }
    guard frame.audio.count <= 32_768, frame.audio.count.isMultiple(of: 2) else {
      throw AppError.provider("Apple Speech received an invalid or oversized audio frame.")
    }
    guard !frame.audio.isEmpty else { return }
    let count = frame.audio.count / 2
    guard let buffer = AVAudioPCMBuffer(pcmFormat: current.sourceFormat, frameCapacity: AVAudioFrameCount(count)),
          let samples = buffer.floatChannelData?[0] else { throw AppError.provider("Cannot allocate Apple Speech audio.") }
    buffer.frameLength = AVAudioFrameCount(count)
    frame.audio.withUnsafeBytes { bytes in
      for index in 0..<count {
        samples[index] = Float(Int16(littleEndian: bytes.loadUnaligned(fromByteOffset: index * 2, as: Int16.self))) / 32768
      }
    }
    for input in try convert(buffer, session: current) {
      guard generation == id, !Task.isCancelled else { throw CancellationError() }
      try await current.input.send(input)
    }
    guard generation == id, !Task.isCancelled else { throw CancellationError() }
  }

  private func convert(_ input: AVAudioPCMBuffer?, session: Session) throws -> [AnalyzerInput] {
    let capacity = AVAudioFrameCount(ceil(session.format.sampleRate) + 4096)
    let source = AppleConverterInput(input)
    var converted: [AnalyzerInput] = []
    // Drain all output, including resampler latency at end of input.
    while true {
      guard let output = AVAudioPCMBuffer(pcmFormat: session.format, frameCapacity: capacity) else {
        throw AppError.provider("Cannot allocate Apple Speech audio.")
      }
      var error: NSError?
      let status = session.converter.convert(to: output, error: &error) { _, state in
        source.next(state)
      }
      if let error { throw error }
      if output.frameLength > 0 {
        converted.append(AnalyzerInput(buffer: output))
      }
      switch status {
      case .haveData: continue
      case .inputRanDry, .endOfStream: return converted
      case .error: throw AppError.provider("Apple Speech audio conversion failed.")
      @unknown default: throw AppError.provider("Apple Speech audio conversion failed.")
      }
    }
  }

  func finish() async throws -> String {
    guard let current = session, !current.finishing else { throw CancellationError() }
    let id = generation
    current.finishing = true
    do {
      if let failure = current.failure { throw failure }
      for input in try convert(nil, session: current) {
        guard generation == id, !Task.isCancelled else { throw CancellationError() }
        try await current.input.send(input)
      }
      guard generation == id, !Task.isCancelled else { throw CancellationError() }
      current.input.finish()
      try await current.analyzer.finalizeAndFinishThroughEndOfInput()
      try await current.results?.value
      guard generation == id, !Task.isCancelled else { throw CancellationError() }
      let text = current.transcript.text
      session = nil
      guard !text.isEmpty else { throw AppError.emptyTranscript }
      onTranscript?(RealtimeTranscriptUpdate(snapshot: TranscriptSnapshot(confirmed: text),
        hasFinalText: true, finalAudioProcessedMS: nil, totalAudioProcessedMS: nil))
      return text
    } catch {
      if generation == id { cancel() }
      throw error
    }
  }

  func cancel() {
    generation = UUID()
    guard let current = session else { return }
    session = nil
    current.input.cancel()
    current.results?.cancel()
    Task { await current.analyzer.cancelAndFinishNow() }
  }
}

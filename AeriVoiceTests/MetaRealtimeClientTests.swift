import Foundation
import XCTest

@testable import AeriVoice

@MainActor
final class MetaRealtimeClientTests: XCTestCase {
  func testHandshakeMatchesMetaRealtimeProtocol() throws {
    let handshake = MetaRealtimeHandshake(
      apiKey: "test-key",
      configuration: TranscriptionConfiguration(provider: .meta),
      vocabulary: ["AeriVoice", "Muse"])

    let object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(handshake)) as? [String: Any])
    let authorization = try XCTUnwrap(object["authorization"] as? [String: String])

    XCTAssertEqual(authorization["accessToken"], "Bearer test-key")
    XCTAssertEqual(object["audioEncoding"] as? String, "PCM_16KHZ")
    XCTAssertEqual(object["model"] as? String, "muse-voice-transcribe-1.0")
    XCTAssertEqual(object["mode"] as? String, "PUSH_TO_TALK")
    XCTAssertEqual(object["partialMode"] as? String, "CUMULATIVE")
    XCTAssertEqual(object["emitAudioProgress"] as? Bool, false)
    XCTAssertEqual(object["keywords"] as? [String], ["AeriVoice", "Muse"])
    XCTAssertEqual(object["zdrOverride"] as? Bool, true)
    XCTAssertNil(object["languageBias"])
  }

  func testHandshakeOmitsEmptyKeywords() throws {
    let handshake = MetaRealtimeHandshake(
      apiKey: "test-key",
      configuration: TranscriptionConfiguration(provider: .meta), vocabulary: [])

    let object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(handshake)) as? [String: Any])

    XCTAssertNil(object["keywords"])
  }

  func testSessionAcknowledgementDecodesWithoutType() throws {
    let response = try JSONDecoder().decode(
      MetaRealtimeResponse.self, from: Data(#"{"sessionId":"session-123"}"#.utf8))

    XCTAssertEqual(response.sessionID, "session-123")
    XCTAssertNil(response.type)
    XCTAssertNil(response.transcriptUpdate)
  }

  func testCumulativePartialAndFinalResponsesBecomeSnapshots() throws {
    let partial = try JSONDecoder().decode(
      MetaRealtimeResponse.self,
      from: Data(#"{"type":"transcript","transcript":"hello wor","final":false}"#.utf8))
    let final = try JSONDecoder().decode(
      MetaRealtimeResponse.self,
      from: Data(#"{"type":"transcript","transcript":"hello world","final":true}"#.utf8))

    XCTAssertEqual(
      partial.transcriptUpdate,
      RealtimeTranscriptUpdate(
        snapshot: TranscriptSnapshot(provisional: "hello wor"), hasFinalText: false,
        finalAudioProcessedMS: nil, totalAudioProcessedMS: nil))
    XCTAssertEqual(
      final.transcriptUpdate,
      RealtimeTranscriptUpdate(
        snapshot: TranscriptSnapshot(confirmed: "hello world"), hasFinalText: true,
        finalAudioProcessedMS: nil, totalAudioProcessedMS: nil))
  }

  func testWhitespaceFinalDoesNotClaimFinalText() throws {
    let response = try JSONDecoder().decode(
      MetaRealtimeResponse.self,
      from: Data(#"{"type":"transcript","transcript":"  ","final":true}"#.utf8))

    XCTAssertEqual(response.transcriptUpdate?.hasFinalText, false)
  }

  func testTransportUsesExactURLSendsHandshakeFirstAndStreamsBinaryAudio() async throws {
    let transport = MetaTransportSpy(mode: .open)
    var capturedURL: URL?
    let client = MetaRealtimeClient(makeTransport: { url in
      capturedURL = url
      return transport
    })

    try await client.connect(
      configuration: TranscriptionConfiguration(provider: .meta), apiKey: "test-key",
      vocabulary: ["AeriVoice"],
      sessionID: DictationSessionID(UUID(uuidString: "00000000-0000-0000-0000-000000000123")!))
    try await client.send(
      RealtimeAudioFrame(audio: Data([1, 2, 3]), queuedBytesAfterFrame: 0))

    XCTAssertEqual(capturedURL?.scheme, "wss")
    XCTAssertEqual(capturedURL?.host, "api.meta.ai")
    XCTAssertEqual(capturedURL?.path, "/v1/asr/realtime")
    XCTAssertEqual(
      URLComponents(url: try XCTUnwrap(capturedURL), resolvingAgainstBaseURL: false)?.queryItems,
      [URLQueryItem(name: "sessionId", value: "00000000-0000-0000-0000-000000000123")])
    XCTAssertEqual(transport.events.prefix(3), [.resumed, .sentText, .received])
    guard case .string(let handshake) = transport.sentMessages.first else {
      return XCTFail("Expected the handshake to be the first WebSocket message")
    }
    XCTAssertTrue(handshake.contains(#""model":"muse-voice-transcribe-1.0""#))
    guard case .data(let audio) = transport.sentMessages.last else {
      return XCTFail("Expected binary PCM audio")
    }
    XCTAssertEqual(audio, Data([1, 2, 3]))
    client.cancel()
  }

  func testAcknowledgementTimeoutActivelyCancelsHangingTransport() async {
    let transport = MetaTransportSpy(mode: .neverAcknowledges)
    let client = MetaRealtimeClient(
      acknowledgementTimeout: .milliseconds(20), makeTransport: { _ in transport })

    do {
      try await client.connect(
        configuration: TranscriptionConfiguration(provider: .meta), apiKey: "test-key",
        vocabulary: [], sessionID: DictationSessionID())
      XCTFail("Expected connection timeout")
    } catch {
      XCTAssertEqual(
        error.localizedDescription, "The transcription provider did not connect in time.")
    }

    XCTAssertTrue(transport.cancelCodes.contains(.goingAway))
  }

  func testHandshakeCloseCodesReturnActionableErrors() async {
    let cases: [(Int, String)] = [
      (1008, "Meta Model API rejected the request or audio pacing."),
      (1011, "Meta Model API had a temporary internal error. Try again."),
      (1013, "Meta Model API is rate limited. Wait a moment and try again."),
    ]

    for (rawCode, expectedMessage) in cases {
      let transport = MetaTransportSpy(mode: .closesDuringAcknowledgement(rawCode))
      let client = MetaRealtimeClient(makeTransport: { _ in transport })
      do {
        try await client.connect(
          configuration: TranscriptionConfiguration(provider: .meta), apiKey: "test-key",
          vocabulary: [], sessionID: DictationSessionID())
        XCTFail("Expected close code \(rawCode)")
      } catch {
        XCTAssertEqual(error.localizedDescription, expectedMessage)
      }
    }
  }

  func testCancelledOldConnectionCannotCancelReusedClient() async throws {
    let oldTransport = MetaTransportSpy(mode: .neverAcknowledges)
    let newTransport = MetaTransportSpy(mode: .open)
    var transports: [MetaTransportSpy] = [oldTransport, newTransport]
    let client = MetaRealtimeClient(
      acknowledgementTimeout: .seconds(1), makeTransport: { _ in transports.removeFirst() })
    let oldConnection = Task { @MainActor in
      do {
        try await client.connect(
          configuration: TranscriptionConfiguration(provider: .meta), apiKey: "old-key",
          vocabulary: [], sessionID: DictationSessionID())
        return nil as Error?
      } catch {
        return error
      }
    }
    for _ in 0..<100 where !oldTransport.events.contains(.received) { await Task.yield() }
    XCTAssertTrue(oldTransport.events.contains(.received))

    oldConnection.cancel()
    try await client.connect(
      configuration: TranscriptionConfiguration(provider: .meta), apiKey: "new-key",
      vocabulary: [], sessionID: DictationSessionID())
    try await client.send(
      RealtimeAudioFrame(audio: Data([9]), queuedBytesAfterFrame: 0))
    _ = await oldConnection.value

    XCTAssertTrue(
      newTransport.sentMessages.contains {
        if case .data(let data) = $0 { return data == Data([9]) }
        return false
      })
    client.cancel()
  }

  func testFinishSendsEndStreamAndWaitsForServerNormalClose() async throws {
    let transport = MetaTransportSpy(mode: .finalAfterEndStream)
    let client = MetaRealtimeClient(makeTransport: { _ in transport })
    try await client.connect(
      configuration: TranscriptionConfiguration(provider: .meta), apiKey: "test-key",
      vocabulary: [], sessionID: DictationSessionID())

    let transcript = try await client.finish()

    XCTAssertEqual(transcript, "final words")
    XCTAssertTrue(
      transport.sentMessages.contains {
        if case .string(#"{"type":"endStream"}"#) = $0 { return true }
        return false
      })
    XCTAssertTrue(transport.cancelCodes.isEmpty)
    XCTAssertTrue(transport.serverClosed)
  }

  func testFinalTranscriptDoesNotFinishBeforeServerCloses() async throws {
    let transport = MetaTransportSpy(mode: .finalWaitingForClose)
    let client = MetaRealtimeClient(makeTransport: { _ in transport })
    try await client.connect(
      configuration: TranscriptionConfiguration(provider: .meta), apiKey: "test-key",
      vocabulary: [], sessionID: DictationSessionID())

    var didFinish = false
    let finishTask = Task { @MainActor in
      defer { didFinish = true }
      return try await client.finish()
    }
    for _ in 0..<100 where !transport.finalDelivered { await Task.yield() }

    XCTAssertTrue(transport.finalDelivered)
    XCTAssertFalse(didFinish)

    transport.finishServerClose()
    let transcript = try await finishTask.value
    XCTAssertEqual(transcript, "final words")
    XCTAssertTrue(didFinish)
  }

  func testNormalCloseRecoversLatestCumulativeTranscript() async throws {
    let transport = MetaTransportSpy(mode: .partialThenNormalClose)
    let client = MetaRealtimeClient(makeTransport: { _ in transport })
    try await client.connect(
      configuration: TranscriptionConfiguration(provider: .meta), apiKey: "test-key",
      vocabulary: [], sessionID: DictationSessionID())

    let transcript = try await client.finish()
    XCTAssertEqual(transcript, "partial words")
    XCTAssertTrue(transport.serverClosed)
  }

  func testGracefulTLSCloseRecoversLatestCumulativeTranscript() async throws {
    let transport = MetaTransportSpy(mode: .partialThenGracefulTLSClose)
    let client = MetaRealtimeClient(makeTransport: { _ in transport })
    try await client.connect(
      configuration: TranscriptionConfiguration(provider: .meta), apiKey: "test-key",
      vocabulary: [], sessionID: DictationSessionID())

    let transcript = try await client.finish()
    XCTAssertEqual(transcript, "partial words")
  }

  func testNormalCloseWithoutTranscriptReturnsNoSpeech() async throws {
    let transport = MetaTransportSpy(mode: .normalCloseWithoutTranscript)
    let client = MetaRealtimeClient(makeTransport: { _ in transport })
    try await client.connect(
      configuration: TranscriptionConfiguration(provider: .meta), apiKey: "test-key",
      vocabulary: [], sessionID: DictationSessionID())

    do {
      _ = try await client.finish()
      XCTFail("Expected no speech")
    } catch {
      XCTAssertEqual(error.localizedDescription, "No speech detected.")
    }
  }

  func testProviderErrorEventIsNotRecoveredAsPartialTranscript() async throws {
    let transport = MetaTransportSpy(mode: .partialThenErrorAfterEndStream)
    let client = MetaRealtimeClient(makeTransport: { _ in transport })
    try await client.connect(
      configuration: TranscriptionConfiguration(provider: .meta), apiKey: "test-key",
      vocabulary: [], sessionID: DictationSessionID())

    do {
      _ = try await client.finish()
      XCTFail("Expected provider failure")
    } catch {
      XCTAssertEqual(error.localizedDescription, "Meta rejected this stream.")
    }
  }

  func testFinalizationTimeoutCancelsHangingTransport() async throws {
    let transport = MetaTransportSpy(mode: .open)
    let client = MetaRealtimeClient(
      finalizationTimeout: .milliseconds(20), makeTransport: { _ in transport })
    try await client.connect(
      configuration: TranscriptionConfiguration(provider: .meta), apiKey: "test-key",
      vocabulary: [], sessionID: DictationSessionID())

    do {
      _ = try await client.finish()
      XCTFail("Expected finalization timeout")
    } catch {
      XCTAssertEqual(error.localizedDescription, "The transcription provider did not finish in time.")
    }
    XCTAssertTrue(transport.cancelCodes.contains(.goingAway))
  }

  func testAudioCannotBeSentAfterEndStream() async throws {
    let transport = MetaTransportSpy(mode: .finalWaitingForClose)
    let client = MetaRealtimeClient(makeTransport: { _ in transport })
    try await client.connect(
      configuration: TranscriptionConfiguration(provider: .meta), apiKey: "test-key",
      vocabulary: [], sessionID: DictationSessionID())

    let finishTask = Task { @MainActor in try await client.finish() }
    for _ in 0..<100 where !transport.endStreamSent { await Task.yield() }
    do {
      try await client.send(
        RealtimeAudioFrame(audio: Data([1, 2]), queuedBytesAfterFrame: 0))
      XCTFail("Expected ended-input error")
    } catch {
      XCTAssertEqual(error.localizedDescription, "Meta Model API has already ended audio input.")
    }
    transport.finishServerClose()
    _ = try await finishTask.value
  }

  func testEndStreamFailureMapsCloseCodeOnceAndSuppressesLateReceiveError() async throws {
    let transport = MetaTransportSpy(mode: .endStreamFails(1013))
    let client = MetaRealtimeClient(makeTransport: { _ in transport })
    var receivedErrors: [Error] = []
    client.onError = { receivedErrors.append($0) }
    try await client.connect(
      configuration: TranscriptionConfiguration(provider: .meta), apiKey: "test-key",
      vocabulary: [], sessionID: DictationSessionID())
    for _ in 0..<100 where transport.events.filter({ $0 == .received }).count < 2 {
      await Task.yield()
    }
    XCTAssertEqual(transport.events.filter({ $0 == .received }).count, 2)

    do {
      _ = try await client.finish()
      XCTFail("Expected endStream failure")
    } catch {
      XCTAssertEqual(
        error.localizedDescription,
        "Meta Model API is rate limited. Wait a moment and try again.")
    }
    await Task.yield()

    XCTAssertTrue(receivedErrors.isEmpty)
  }

  func testNormalCloseBeforeEndStreamFailureDoesNotRecoverPartialTranscript() async throws {
    let transport = MetaTransportSpy(mode: .normalCloseBeforeEndStreamFails)
    let client = MetaRealtimeClient(makeTransport: { _ in transport })
    try await client.connect(
      configuration: TranscriptionConfiguration(provider: .meta), apiKey: "test-key",
      vocabulary: [], sessionID: DictationSessionID())

    let finishTask = Task { @MainActor in try await client.finish() }
    for _ in 0..<100 where !transport.endStreamSendSuspended { await Task.yield() }
    XCTAssertTrue(transport.endStreamSendSuspended)
    for _ in 0..<10 { await Task.yield() }
    transport.releaseEndStreamSend()

    do {
      _ = try await finishTask.value
      XCTFail("Expected the failed endStream send to fail finalization")
    } catch let error as URLError {
      XCTAssertEqual(error.code, .networkConnectionLost)
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  func testNormalCloseWaitsForSuccessfulEndStreamSendBeforeRecoveringPartial() async throws {
    let transport = MetaTransportSpy(mode: .normalCloseBeforeEndStreamSucceeds)
    let client = MetaRealtimeClient(makeTransport: { _ in transport })
    try await client.connect(
      configuration: TranscriptionConfiguration(provider: .meta), apiKey: "test-key",
      vocabulary: [], sessionID: DictationSessionID())

    let finishTask = Task { @MainActor in try await client.finish() }
    for _ in 0..<100 where !transport.endStreamSendSuspended { await Task.yield() }
    XCTAssertTrue(transport.endStreamSendSuspended)
    for _ in 0..<10 { await Task.yield() }
    transport.releaseEndStreamSend()

    let transcript = try await finishTask.value
    XCTAssertEqual(transcript, "partial words")
  }

  func testFinalizationCloseCodesReturnActionableErrors() async throws {
    let cases: [(Int, String)] = [
      (1008, "Meta Model API rejected the request or audio pacing."),
      (1011, "Meta Model API had a temporary internal error. Try again."),
      (1013, "Meta Model API is rate limited. Wait a moment and try again."),
    ]

    for (rawCode, expectedMessage) in cases {
      let transport = MetaTransportSpy(mode: .closesAfterEndStream(rawCode))
      let client = MetaRealtimeClient(makeTransport: { _ in transport })
      try await client.connect(
        configuration: TranscriptionConfiguration(provider: .meta), apiKey: "test-key",
        vocabulary: [], sessionID: DictationSessionID())

      do {
        _ = try await client.finish()
        XCTFail("Expected close code \(rawCode)")
      } catch {
        XCTAssertEqual(error.localizedDescription, expectedMessage)
      }
    }
  }

  func testPacingOffsetMatchesSixteenKilohertzPCMByteRate() {
    XCTAssertEqual(MetaRealtimeClient.pacingOffset(forByteCount: 0), .zero)
    XCTAssertEqual(MetaRealtimeClient.pacingOffset(forByteCount: 3_200), .milliseconds(100))
    XCTAssertEqual(
      MetaRealtimeClient.pacingOffset(forByteCount: 3_200, speedMultiplier: 1.35),
      .nanoseconds(74_074_074))
    XCTAssertEqual(MetaRealtimeClient.pacingOffset(forByteCount: 160_000), .seconds(5))
  }

  func testQueuedAudioAppliesBoundedCatchUpPacingUntilQueueClears() async throws {
    let transport = MetaTransportSpy(mode: .open)
    let pacingClock = MetaPacingClockSpy()
    let client = MetaRealtimeClient(
      pacingClock: pacingClock, makeTransport: { _ in transport })
    try await client.connect(
      configuration: TranscriptionConfiguration(provider: .meta), apiKey: "test-key",
      vocabulary: [], sessionID: DictationSessionID())

    try await client.send(
      RealtimeAudioFrame(
        audio: Data(repeating: 0, count: 3_200), queuedBytesAfterFrame: 6_400))
    try await client.send(
      RealtimeAudioFrame(
        audio: Data(repeating: 0, count: 3_200), queuedBytesAfterFrame: 3_200))
    try await client.send(
      RealtimeAudioFrame(
        audio: Data(repeating: 0, count: 3_200), queuedBytesAfterFrame: 0))
    try await client.send(
      RealtimeAudioFrame(
        audio: Data(repeating: 0, count: 3_200), queuedBytesAfterFrame: 0))

    XCTAssertEqual(
      pacingClock.sleepDurations,
      [.nanoseconds(74_074_074), .milliseconds(100), .milliseconds(100)])
    XCTAssertEqual(
      transport.sentMessages.compactMap { message -> Data? in
        if case .data(let data) = message { return data }
        return nil
      }.count, 4)
    client.cancel()
  }

  func testPacingDoesNotAddWebSocketSendOverheadToEveryFrame() async throws {
    let transport = MetaTransportSpy(mode: .open)
    let pacingClock = MetaPacingClockSpy()
    transport.onDataSend = { pacingClock.advance(by: .milliseconds(20)) }
    let client = MetaRealtimeClient(
      pacingClock: pacingClock, makeTransport: { _ in transport })
    try await client.connect(
      configuration: TranscriptionConfiguration(provider: .meta), apiKey: "test-key",
      vocabulary: [], sessionID: DictationSessionID())

    for _ in 0..<4 {
      try await client.send(
        RealtimeAudioFrame(audio: Data(repeating: 0, count: 3_200), queuedBytesAfterFrame: 0))
    }

    XCTAssertEqual(
      pacingClock.sleepDurations,
      [.milliseconds(80), .milliseconds(80), .milliseconds(80)])
    client.cancel()
  }

  func testPacingRebasesAfterStallInsteadOfBurstingToCatchUp() async throws {
    let transport = MetaTransportSpy(mode: .open)
    let pacingClock = MetaPacingClockSpy()
    var sendDurations: [Duration] = [.milliseconds(250), .zero, .zero]
    transport.onDataSend = { pacingClock.advance(by: sendDurations.removeFirst()) }
    let client = MetaRealtimeClient(
      pacingClock: pacingClock, makeTransport: { _ in transport })
    try await client.connect(
      configuration: TranscriptionConfiguration(provider: .meta), apiKey: "test-key",
      vocabulary: [], sessionID: DictationSessionID())

    for _ in 0..<3 {
      try await client.send(
        RealtimeAudioFrame(audio: Data(repeating: 0, count: 3_200), queuedBytesAfterFrame: 0))
    }

    XCTAssertEqual(pacingClock.sleepDurations, [.milliseconds(100)])
    client.cancel()
  }

  func testPacingRebasesAfterLateSleepWakeInsteadOfBursting() async throws {
    let transport = MetaTransportSpy(mode: .open)
    let pacingClock = MetaPacingClockSpy()
    pacingClock.sleepOvershoots = [.milliseconds(99), .zero]
    let client = MetaRealtimeClient(
      pacingClock: pacingClock, makeTransport: { _ in transport })
    try await client.connect(
      configuration: TranscriptionConfiguration(provider: .meta), apiKey: "test-key",
      vocabulary: [], sessionID: DictationSessionID())

    for _ in 0..<3 {
      try await client.send(
        RealtimeAudioFrame(audio: Data(repeating: 0, count: 3_200), queuedBytesAfterFrame: 0))
    }

    XCTAssertEqual(pacingClock.sleepDurations, [.milliseconds(100), .milliseconds(100)])
    client.cancel()
  }
}

@MainActor
private final class MetaPacingClockSpy: MetaPacingClock {
  private(set) var now = ContinuousClock.now
  private(set) var sleepDurations: [Duration] = []
  var sleepOvershoots: [Duration] = []

  func sleep(until deadline: ContinuousClock.Instant) async throws {
    sleepDurations.append(now.duration(to: deadline))
    let overshoot = sleepOvershoots.isEmpty ? .zero : sleepOvershoots.removeFirst()
    now = deadline.advanced(by: overshoot)
  }

  func advance(by duration: Duration) {
    now = now.advanced(by: duration)
  }
}

@MainActor
private final class MetaTransportSpy: MetaWebSocketTransport {
  enum Mode {
    case open
    case neverAcknowledges
    case closesDuringAcknowledgement(Int)
    case finalAfterEndStream
    case finalWaitingForClose
    case partialThenNormalClose
    case partialThenGracefulTLSClose
    case normalCloseWithoutTranscript
    case partialThenErrorAfterEndStream
    case closesAfterEndStream(Int)
    case endStreamFails(Int)
    case normalCloseBeforeEndStreamFails
    case normalCloseBeforeEndStreamSucceeds
  }

  enum Event: Equatable {
    case resumed
    case sentText
    case sentData
    case received
  }

  private let mode: Mode
  private var receiveCount = 0
  private var pendingReceive: CheckedContinuation<URLSessionWebSocketTask.Message, Error>?
  private var pendingEndStreamSend: CheckedContinuation<Void, Never>?
  private var queuedReceives: [Result<URLSessionWebSocketTask.Message, Error>] = []
  var onDataSend: (() -> Void)?
  private(set) var sentMessages: [URLSessionWebSocketTask.Message] = []
  private(set) var events: [Event] = []
  private(set) var cancelCodes: [URLSessionWebSocketTask.CloseCode] = []
  private(set) var endStreamSent = false
  private(set) var finalDelivered = false
  private(set) var serverClosed = false
  private(set) var endStreamSendSuspended = false

  init(mode: Mode) { self.mode = mode }

  func resume() { events.append(.resumed) }

  func send(_ message: URLSessionWebSocketTask.Message) async throws {
    sentMessages.append(message)
    switch message {
    case .string(let text):
      events.append(.sentText)
      if text == #"{"type":"endStream"}"# {
        switch mode {
        case .normalCloseBeforeEndStreamFails, .normalCloseBeforeEndStreamSucceeds:
          endStreamSendSuspended = true
          finishServerClose()
          await withCheckedContinuation { pendingEndStreamSend = $0 }
          endStreamSendSuspended = false
          if case .normalCloseBeforeEndStreamFails = mode {
            throw transportError(closeCode: 1000)
          }
        default:
          break
        }
        if case .endStreamFails(let rawCode) = mode {
          let error = transportError(closeCode: rawCode)
          enqueue(.failure(error))
          throw error
        }
        endStreamSent = true
        enqueueEndStreamResponses()
      }
    case .data:
      events.append(.sentData)
      onDataSend?()
    @unknown default:
      break
    }
  }

  func receive() async throws -> URLSessionWebSocketTask.Message {
    events.append(.received)
    receiveCount += 1
    if receiveCount == 1 {
      switch mode {
      case .closesDuringAcknowledgement(let rawCode):
        throw transportError(closeCode: rawCode)
      case .neverAcknowledges:
        return try await suspendReceive()
      case .open, .finalAfterEndStream, .finalWaitingForClose, .partialThenNormalClose,
        .partialThenGracefulTLSClose, .normalCloseWithoutTranscript,
        .partialThenErrorAfterEndStream, .closesAfterEndStream, .endStreamFails,
        .normalCloseBeforeEndStreamFails, .normalCloseBeforeEndStreamSucceeds:
        return .string(#"{"sessionId":"meta-session"}"#)
      }
    }
    if receiveCount == 2 {
      switch mode {
      case .partialThenNormalClose, .partialThenGracefulTLSClose,
        .partialThenErrorAfterEndStream, .normalCloseBeforeEndStreamFails,
        .normalCloseBeforeEndStreamSucceeds:
        return partialMessage
      default:
        break
      }
    }
    if !queuedReceives.isEmpty { return try queuedReceives.removeFirst().get() }
    return try await suspendReceive()
  }

  func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
    cancelCodes.append(closeCode)
    pendingReceive?.resume(throwing: CancellationError())
    pendingReceive = nil
    pendingEndStreamSend?.resume()
    pendingEndStreamSend = nil
    queuedReceives.removeAll()
  }

  func finishServerClose(code: Int = 1000) {
    serverClosed = true
    enqueue(.failure(transportError(closeCode: code)))
  }

  func releaseEndStreamSend() {
    pendingEndStreamSend?.resume()
    pendingEndStreamSend = nil
  }

  private func suspendReceive() async throws -> URLSessionWebSocketTask.Message {
    try await withCheckedThrowingContinuation { pendingReceive = $0 }
  }

  private func enqueueEndStreamResponses() {
    switch mode {
    case .finalAfterEndStream:
      enqueue(.success(finalMessage))
      finishServerClose()
    case .finalWaitingForClose:
      enqueue(.success(finalMessage))
    case .partialThenNormalClose, .normalCloseWithoutTranscript:
      finishServerClose()
    case .partialThenGracefulTLSClose:
      serverClosed = true
      let gracefulClose = NSError(domain: NSOSStatusErrorDomain, code: -9805)
      enqueue(
        .failure(MetaWebSocketTransportError(underlying: gracefulClose, closeCode: nil)))
    case .partialThenErrorAfterEndStream:
      enqueue(
        .success(
          .string(#"{"type":"error","message":"Meta rejected this stream."}"#)))
    case .closesAfterEndStream(let rawCode):
      finishServerClose(code: rawCode)
    case .open, .neverAcknowledges, .closesDuringAcknowledgement, .endStreamFails,
      .normalCloseBeforeEndStreamFails, .normalCloseBeforeEndStreamSucceeds:
      break
    }
  }

  private func enqueue(_ result: Result<URLSessionWebSocketTask.Message, Error>) {
    guard let pendingReceive else {
      queuedReceives.append(result)
      return
    }
    self.pendingReceive = nil
    resume(pendingReceive, with: result)
  }

  private func resume(
    _ continuation: CheckedContinuation<URLSessionWebSocketTask.Message, Error>,
    with result: Result<URLSessionWebSocketTask.Message, Error>
  ) {
    switch result {
    case .success(let message): continuation.resume(returning: message)
    case .failure(let error): continuation.resume(throwing: error)
    }
  }

  private func transportError(closeCode: Int?) -> MetaWebSocketTransportError {
    MetaWebSocketTransportError(
      underlying: URLError(.networkConnectionLost), closeCode: closeCode)
  }

  private var finalMessage: URLSessionWebSocketTask.Message {
    finalDelivered = true
    return .string(#"{"type":"transcript","transcript":"final words","final":true}"#)
  }

  private var partialMessage: URLSessionWebSocketTask.Message {
    .string(#"{"type":"transcript","transcript":"partial words","final":false}"#)
  }
}

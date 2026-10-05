import Foundation
import XCTest

@testable import AeriVoice

@MainActor
final class CartesiaRealtimeClientTests: XCTestCase {
  // MARK: - Request

  func testRequestTargetsManualFinalizeEndpointWithHeaderAuth() throws {
    let request = CartesiaRealtimeRequest.make(
      apiKey: "sk_car_test", model: "ink-2", vocabulary: [])
    let url = try XCTUnwrap(request.url)
    XCTAssertEqual(url.scheme, "wss")
    XCTAssertEqual(url.host, "api.cartesia.ai")
    XCTAssertEqual(url.path, "/stt/websocket")
    XCTAssertEqual(
      URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
      [
        URLQueryItem(name: "model", value: "ink-2"),
        URLQueryItem(name: "encoding", value: "pcm_s16le"),
        URLQueryItem(name: "sample_rate", value: "16000"),
        URLQueryItem(name: "cartesia_version", value: "2026-08-14"),
      ])
    XCTAssertEqual(request.value(forHTTPHeaderField: "X-API-Key"), "sk_car_test")
    XCTAssertFalse(url.absoluteString.contains("sk_car_test"), "The key never goes in the URL")
  }

  func testKeytermsAreRepeatedAndEscapedSoTheyArriveExactly() throws {
    let terms = ["Ink 2", "C++", "AT&T", "a=b", "naïve", "50%"]
    let request = CartesiaRealtimeRequest.make(apiKey: "key", model: "ink-preview", vocabulary: terms)
    let components = try XCTUnwrap(
      URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
    let query = try XCTUnwrap(components.percentEncodedQuery)
    XCTAssertTrue(query.contains("keyterm=Ink%202"))
    XCTAssertTrue(query.contains("keyterm=C%2B%2B"))
    XCTAssertTrue(query.contains("keyterm=AT%26T"))
    XCTAssertTrue(query.contains("keyterm=a%3Db"))
    XCTAssertTrue(query.contains("keyterm=50%25"))
    XCTAssertEqual(
      components.queryItems?.filter { $0.name == "keyterm" }.compactMap(\.value), terms)
    XCTAssertEqual(components.queryItems?.first { $0.name == "model" }?.value, "ink-preview")
  }

  func testKeytermsKeepTheFirstHundredTerms() {
    let vocabulary = (1...150).map { "term\($0)" }
    let keyterms = CartesiaKeyterms(vocabulary)
    XCTAssertEqual(keyterms.terms, Array(vocabulary.prefix(100)))
    XCTAssertEqual(keyterms.excluded, Array(vocabulary.suffix(50)))
  }

  func testKeytermsStayWithinTheCharacterBudgetAndSkipOnlyWhatDoesNotFit() {
    let long = String(repeating: "a", count: 600)
    let alsoLong = String(repeating: "b", count: 590)
    let tooLong = String(repeating: "c", count: 20)
    let keyterms = CartesiaKeyterms([long, alsoLong, tooLong, "short", "Short", "  "])
    // 600 + 590 leaves 10 characters: the 20-character term is skipped, "short" still fits,
    // and the duplicate and the blank entry are dropped as everywhere else.
    XCTAssertEqual(keyterms.terms, [long, alsoLong, "short"])
    XCTAssertEqual(keyterms.excluded, [tooLong])
    XCTAssertLessThanOrEqual(
      keyterms.terms.reduce(0) { $0 + $1.unicodeScalars.count },
      CartesiaKeyterms.maximumCharacters)
  }

  func testConnectSendsTheSelectedModelAndDictionary() async throws {
    let transport = CartesiaTransportSpy()
    var captured: URLRequest?
    let client = CartesiaRealtimeClient(makeTransport: { request in
      captured = request
      return transport
    })

    try await client.connect(
      configuration: TranscriptionConfiguration(provider: .cartesia, cartesiaModel: .inkPreview),
      apiKey: "sk_car_test", vocabulary: ["AeriVoice", "Ink 2"], sessionID: DictationSessionID())

    let url = try XCTUnwrap(captured?.url)
    let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    XCTAssertEqual(items.first { $0.name == "model" }?.value, "ink-preview")
    XCTAssertEqual(
      items.filter { $0.name == "keyterm" }.compactMap(\.value), ["AeriVoice", "Ink 2"])
    XCTAssertEqual(captured?.value(forHTTPHeaderField: "X-API-Key"), "sk_car_test")
    XCTAssertEqual(transport.openCount, 1)
    XCTAssertTrue(transport.sentMessages.isEmpty, "Cartesia has no handshake message")
    client.cancel()
  }

  func testOtherProvidersAreRejectedBeforeAnySocketOpens() async {
    var made = 0
    let client = CartesiaRealtimeClient(makeTransport: { _ in
      made += 1
      return CartesiaTransportSpy()
    })
    do {
      try await client.connect(
        configuration: TranscriptionConfiguration(provider: .soniox), apiKey: "key",
        vocabulary: [], sessionID: DictationSessionID())
      XCTFail("Expected the provider mismatch to throw")
    } catch {
      XCTAssertEqual(
        error.localizedDescription,
        "The selected transcription model is not available through Cartesia.")
    }
    XCTAssertEqual(made, 0)
  }

  // MARK: - Transcripts

  func testFinalChunksJoinExactlyAndInterimTextIsProvisional() async throws {
    let transport = CartesiaTransportSpy()
    let client = CartesiaRealtimeClient(makeTransport: { _ in transport })
    var updates: [RealtimeTranscriptUpdate] = []
    client.onTranscript = { updates.append($0) }
    try await connect(client)

    transport.serverSends(#"{"type":"transcript","is_final":false,"text":"This is"}"#)
    transport.serverSends(#"{"type":"transcript","is_final":true,"text":"This is a"}"#)
    transport.serverSends(#"{"type":"transcript","is_final":false,"text":" single sen"}"#)
    transport.serverSends(#"{"type":"transcript","is_final":true,"text":" single sentence."}"#)
    try await waitUntil { updates.count == 4 }

    XCTAssertEqual(
      updates.map(\.snapshot),
      [
        TranscriptSnapshot(provisional: "This is"),
        TranscriptSnapshot(confirmed: "This is a"),
        TranscriptSnapshot(confirmed: "This is a", provisional: " single sen"),
        TranscriptSnapshot(confirmed: "This is a single sentence."),
      ])
    XCTAssertEqual(updates.map(\.hasFinalText), [false, true, false, true])
    client.cancel()
  }

  func testChunksThatSplitAWordAreNotSeparatedOrTrimmed() async throws {
    let transport = CartesiaTransportSpy()
    transport.replies["close"] = [.success(.string(#"{"type":"done"}"#))]
    let client = CartesiaRealtimeClient(makeTransport: { _ in transport })
    try await connect(client)
    transport.serverSends(#"{"type":"transcript","is_final":true,"text":" Insert"}"#)
    transport.serverSends(#"{"type":"transcript","is_final":true,"text":"ing spaces is not safe. "}"#)

    let transcript = try await client.finish()

    XCTAssertEqual(transcript, "Inserting spaces is not safe.")
  }

  func testWhitespaceOnlyFinalDoesNotClaimFinalText() async throws {
    let transport = CartesiaTransportSpy()
    let client = CartesiaRealtimeClient(makeTransport: { _ in transport })
    var updates: [RealtimeTranscriptUpdate] = []
    client.onTranscript = { updates.append($0) }
    try await connect(client)
    transport.serverSends(#"{"type":"transcript","is_final":true,"text":" "}"#)
    try await waitUntil { updates.count == 1 }
    XCTAssertEqual(updates.first?.hasFinalText, false)
    client.cancel()
  }

  // MARK: - Finishing

  func testFinishSendsFinalizeThenCloseAndWaitsForDone() async throws {
    let transport = CartesiaTransportSpy()
    transport.replies["finalize"] = [
      .success(.string(#"{"type":"transcript","is_final":true,"text":"Hello world."}"#)),
      .success(.string(#"{"type":"flush_done","request_id":"r"}"#)),
    ]
    let client = CartesiaRealtimeClient(makeTransport: { _ in transport })
    try await connect(client)
    try await client.send(RealtimeAudioFrame(audio: Data([1, 2, 3]), queuedBytesAfterFrame: 0))

    let finishing = Task { try await client.finish() }
    try await waitUntil { transport.sentText == ["finalize", "close"] }
    for _ in 0..<20 { await Task.yield() }
    XCTAssertTrue(transport.cancelCodes.isEmpty, "flush_done alone does not end the session")

    transport.serverSends(#"{"type":"done","request_id":"r"}"#)
    let transcript = try await finishing.value

    XCTAssertEqual(transcript, "Hello world.")
    XCTAssertEqual(transport.sentData, [Data([1, 2, 3])])
    XCTAssertEqual(transport.cancelCodes, [.normalClosure])
  }

  func testDoneWithoutSpeechReportsNoSpeech() async throws {
    let transport = CartesiaTransportSpy()
    transport.replies["close"] = [.success(.string(#"{"type":"done"}"#))]
    let client = CartesiaRealtimeClient(makeTransport: { _ in transport })
    try await connect(client)

    do {
      _ = try await client.finish()
      XCTFail("Expected no speech")
    } catch AppError.emptyTranscript {
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  func testNormalCloseWithoutDoneReturnsTheTranscriptReceived() async throws {
    let transport = CartesiaTransportSpy()
    transport.replies["finalize"] = [
      .success(.string(#"{"type":"transcript","is_final":true,"text":"Kept text"}"#))
    ]
    transport.replies["close"] = [.failure(CartesiaTransportError(status: 1000))]
    let client = CartesiaRealtimeClient(makeTransport: { _ in transport })
    try await connect(client)

    let transcript = try await client.finish()

    XCTAssertEqual(transcript, "Kept text")
  }

  func testAbnormalCloseWhileFinishingFailsInsteadOfReturningPartialText() async throws {
    let transport = CartesiaTransportSpy()
    transport.replies["finalize"] = [
      .success(.string(#"{"type":"transcript","is_final":true,"text":"Partial"}"#)),
      .failure(CartesiaTransportError(status: 1011)),
    ]
    let client = CartesiaRealtimeClient(makeTransport: { _ in transport })
    try await connect(client)

    do {
      _ = try await client.finish()
      XCTFail("Expected the abnormal close to fail")
    } catch {
      XCTAssertEqual(error as? CartesiaTransportError, CartesiaTransportError(status: 1011))
    }
    XCTAssertEqual(transport.cancelCodes, [.goingAway])
  }

  func testErrorEventWhileFinishingSurfacesCartesiasMessage() async throws {
    let transport = CartesiaTransportSpy()
    transport.replies["finalize"] = [
      .success(
        .string(
          #"{"type":"error","done":true,"status_code":429,"error_code":"concurrency_limited","title":"Too many concurrent requests","message":"You have exceeded your plan's concurrency limit."}"#
        ))
    ]
    let client = CartesiaRealtimeClient(makeTransport: { _ in transport })
    try await connect(client)

    do {
      _ = try await client.finish()
      XCTFail("Expected the provider error")
    } catch {
      XCTAssertEqual(
        error.localizedDescription,
        "Cartesia: You have exceeded your plan's concurrency limit.")
    }
  }

  func testErrorEventWhileStreamingReachesTheErrorHandler() async throws {
    let transport = CartesiaTransportSpy()
    let client = CartesiaRealtimeClient(makeTransport: { _ in transport })
    var errors: [String] = []
    client.onError = { errors.append($0.localizedDescription) }
    try await connect(client)

    transport.serverSends(#"{"type":"error","title":"Unexpected error"}"#)
    try await waitUntil { !errors.isEmpty }

    XCTAssertEqual(errors, ["Cartesia: Unexpected error"])
  }

  func testUnknownEventsAreIgnored() async throws {
    let transport = CartesiaTransportSpy()
    transport.replies["close"] = [.success(.string(#"{"type":"done"}"#))]
    let client = CartesiaRealtimeClient(makeTransport: { _ in transport })
    try await connect(client)
    transport.serverSends(#"{"type":"connected","request_id":"r"}"#)
    transport.serverSends(#"{"request_id":"r"}"#)
    transport.serverSends(#"{"type":"transcript","is_final":true,"text":"Still fine"}"#)

    let transcript = try await client.finish()

    XCTAssertEqual(transcript, "Still fine")
  }

  func testFinalizationTimeoutCancelsAHangingSocket() async throws {
    let transport = CartesiaTransportSpy()
    let client = CartesiaRealtimeClient(
      finalizationTimeout: .milliseconds(20), makeTransport: { _ in transport })
    try await connect(client)

    do {
      _ = try await client.finish()
      XCTFail("Expected the finalize timeout")
    } catch {
      XCTAssertEqual(
        error.localizedDescription, "The transcription provider did not finish in time.")
    }
    XCTAssertEqual(transport.cancelCodes, [.goingAway])
  }

  func testAudioCannotBeSentOnceFinishHasStarted() async throws {
    let transport = CartesiaTransportSpy()
    let client = CartesiaRealtimeClient(makeTransport: { _ in transport })
    try await connect(client)
    let finishing = Task { try await client.finish() }
    try await waitUntil { transport.sentText == ["finalize", "close"] }

    do {
      try await client.send(RealtimeAudioFrame(audio: Data([9]), queuedBytesAfterFrame: 0))
      XCTFail("Expected audio to be refused")
    } catch {
      XCTAssertEqual(error.localizedDescription, "Cartesia has already ended audio input.")
    }
    XCTAssertTrue(transport.sentData.isEmpty)

    client.cancel()
    do {
      _ = try await finishing.value
      XCTFail("Expected cancellation")
    } catch is CancellationError {
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
    XCTAssertEqual(transport.cancelCodes, [.goingAway])
  }

  func testFailedFinalizeSendFailsTheDictation() async throws {
    let transport = CartesiaTransportSpy()
    transport.sendFailure = CartesiaTransportError(status: 1006)
    let client = CartesiaRealtimeClient(makeTransport: { _ in transport })
    try await connect(client)

    do {
      _ = try await client.finish()
      XCTFail("Expected the send failure")
    } catch {
      XCTAssertEqual(error as? CartesiaTransportError, CartesiaTransportError(status: 1006))
    }
  }

  // MARK: - Connecting

  func testRefusedHandshakeReportsTheKeyRejection() async {
    let transport = CartesiaTransportSpy()
    transport.openBehavior = .fails(CartesiaTransportError(status: 401))
    let client = CartesiaRealtimeClient(makeTransport: { _ in transport })

    do {
      try await connect(client)
      XCTFail("Expected the handshake to be refused")
    } catch {
      XCTAssertEqual(error.localizedDescription, "Cartesia rejected this API key.")
    }
    XCTAssertEqual(transport.cancelCodes, [.goingAway])
    do {
      try await client.send(RealtimeAudioFrame(audio: Data([1]), queuedBytesAfterFrame: 0))
      XCTFail("Expected no connection")
    } catch {
      XCTAssertEqual(error.localizedDescription, "Cartesia is not connected.")
    }
  }

  func testConnectionTimeoutCancelsAHangingHandshake() async {
    let transport = CartesiaTransportSpy()
    transport.openBehavior = .hangs
    let client = CartesiaRealtimeClient(
      connectionTimeout: .milliseconds(20), makeTransport: { _ in transport })

    do {
      try await connect(client)
      XCTFail("Expected the connection timeout")
    } catch {
      XCTAssertEqual(
        error.localizedDescription, "The transcription provider did not connect in time.")
    }
    XCTAssertTrue(transport.cancelCodes.contains(.goingAway))
  }

  func testCancelDuringHandshakeThrowsCancellationAndLeavesTheNextConnectionAlone() async throws {
    let first = CartesiaTransportSpy()
    first.openBehavior = .hangs
    let second = CartesiaTransportSpy()
    var transports = [first, second]
    let client = CartesiaRealtimeClient(makeTransport: { _ in transports.removeFirst() })

    let connecting = Task { try await self.connect(client) }
    try await waitUntil { first.openCount == 1 }
    try await connect(client)
    do {
      try await connecting.value
      XCTFail("Expected the first connection to be cancelled")
    } catch is CancellationError {
    } catch {
      XCTFail("Unexpected error: \(error)")
    }

    XCTAssertEqual(first.cancelCodes, [.goingAway])
    XCTAssertTrue(second.cancelCodes.isEmpty)
    try await client.send(RealtimeAudioFrame(audio: Data([7]), queuedBytesAfterFrame: 0))
    XCTAssertEqual(second.sentData, [Data([7])])
    client.cancel()
  }

  func testTransportErrorsDescribeWhatTheUserCanDo() {
    XCTAssertEqual(
      CartesiaTransportError(status: 403).localizedDescription, "Cartesia rejected this API key.")
    XCTAssertEqual(
      CartesiaTransportError(status: 429).localizedDescription,
      "Cartesia is rate limited or at your plan's connection limit. Wait a moment and try again.")
    XCTAssertEqual(
      CartesiaTransportError(status: nil).localizedDescription,
      "The Cartesia transcription connection failed. Try again.")
    XCTAssertEqual(CartesiaTransportError(status: 401).httpStatus, 401)
    XCTAssertNil(CartesiaTransportError(status: 1011).httpStatus)
    XCTAssertTrue(CartesiaTransportError(status: 401).isProviderRejection)
    XCTAssertTrue(CartesiaTransportError(status: 1011).isProviderRejection)
    XCTAssertFalse(CartesiaTransportError(status: 1006).isProviderRejection)
    XCTAssertFalse(CartesiaTransportError(status: nil).isProviderRejection)
    XCTAssertTrue(CartesiaTransportError(status: 1000).isNormalClosure)
  }

  // MARK: - Pacing

  func testAudioDurationMatchesSixteenKilohertzPCMByteRate() {
    XCTAssertEqual(CartesiaRealtimeClient.audioNanoseconds(forByteCount: 3_200), 100_000_000)
    XCTAssertEqual(CartesiaRealtimeClient.audioNanoseconds(forByteCount: 32_000), 1_000_000_000)
    XCTAssertEqual(
      CartesiaRealtimeClient.catchUpWait(forMissingAudio: 135_000_000), .milliseconds(100))
  }

  func testUpToOneSecondOfBufferedAudioIsSentWithoutWaiting() async throws {
    let transport = CartesiaTransportSpy()
    let time = ManualPacingClock()
    let client = CartesiaRealtimeClient(clock: time.clock, makeTransport: { _ in transport })
    try await connect(client)
    let frame = Data(repeating: 0, count: 3_200)

    // One second was captured while the socket opened.
    for remaining in (0..<10).reversed() {
      try await client.send(
        RealtimeAudioFrame(audio: frame, queuedBytesAfterFrame: remaining * 3_200))
    }
    XCTAssertTrue(time.sleeps.isEmpty)
    XCTAssertEqual(transport.sentData.count, 10)
    client.cancel()
  }

  func testALongerBacklogDrainsAtCatchUpSpeed() async throws {
    let transport = CartesiaTransportSpy()
    let time = ManualPacingClock()
    let client = CartesiaRealtimeClient(clock: time.clock, makeTransport: { _ in transport })
    try await connect(client)
    let frame = Data(repeating: 0, count: 3_200)

    // Three seconds queued: the first second goes at once, the other two at 1.35× realtime.
    for remaining in (0..<30).reversed() {
      try await client.send(
        RealtimeAudioFrame(audio: frame, queuedBytesAfterFrame: remaining * 3_200))
    }

    XCTAssertEqual(time.sleeps.count, 20)
    for sleep in time.sleeps {
      XCTAssertGreaterThan(sleep, .milliseconds(74))
      XCTAssertLessThan(sleep, .milliseconds(75))
    }
    let total = time.sleeps.reduce(Duration.zero, +)
    XCTAssertGreaterThan(total, .milliseconds(1_480))
    XCTAssertLessThan(total, .milliseconds(1_483))
    XCTAssertEqual(transport.sentData.count, 30)
    client.cancel()
  }

  func testLiveAudioNeverWaitsAndTheLastBlockAtReleaseGoesStraightOut() async throws {
    let transport = CartesiaTransportSpy()
    let time = ManualPacingClock()
    let client = CartesiaRealtimeClient(clock: time.clock, makeTransport: { _ in transport })
    try await connect(client)
    let frame = Data(repeating: 0, count: 3_200)

    // The opening backlog uses the whole burst.
    for _ in 0..<10 {
      try await client.send(RealtimeAudioFrame(audio: frame, queuedBytesAfterFrame: 3_200))
    }
    // Live audio then arrives every 100 ms, and the budget refills behind it.
    for _ in 0..<30 {
      time.advance(by: .milliseconds(100))
      try await client.send(RealtimeAudioFrame(audio: frame, queuedBytesAfterFrame: 0))
    }
    // At release the capture pipeline hands over its last audio all at once. The live frame
    // just sent used 100 ms of the budget, so 900 ms more can follow it immediately.
    for _ in 0..<9 {
      try await client.send(RealtimeAudioFrame(audio: frame, queuedBytesAfterFrame: 3_200))
    }
    XCTAssertTrue(time.sleeps.isEmpty)

    try await client.send(RealtimeAudioFrame(audio: frame, queuedBytesAfterFrame: 0))
    XCTAssertEqual(time.sleeps.count, 1, "Audio past the burst waits")
    XCTAssertEqual(transport.sentData.count, 50)
    client.cancel()
  }

  func testANewConnectionStartsWithAFullBurst() async throws {
    let first = CartesiaTransportSpy()
    let second = CartesiaTransportSpy()
    var transports = [first, second]
    let time = ManualPacingClock()
    let client = CartesiaRealtimeClient(
      clock: time.clock, makeTransport: { _ in transports.removeFirst() })
    let frame = Data(repeating: 0, count: 3_200)

    try await connect(client)
    for _ in 0..<10 {
      try await client.send(RealtimeAudioFrame(audio: frame, queuedBytesAfterFrame: 0))
    }
    try await connect(client)
    for _ in 0..<10 {
      try await client.send(RealtimeAudioFrame(audio: frame, queuedBytesAfterFrame: 0))
    }

    XCTAssertTrue(time.sleeps.isEmpty)
    XCTAssertEqual(second.sentData.count, 10)
    client.cancel()
  }

  // MARK: - Helpers

  private func connect(_ client: CartesiaRealtimeClient) async throws {
    try await client.connect(
      configuration: TranscriptionConfiguration(provider: .cartesia), apiKey: "test-key",
      vocabulary: [], sessionID: DictationSessionID())
  }

  private func waitUntil(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while !condition(), ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(1))
    }
    XCTAssertTrue(condition(), "Timed out waiting for the Cartesia client")
  }
}

@MainActor
private final class ManualPacingClock {
  private(set) var now = ContinuousClock.now
  private(set) var sleeps: [Duration] = []

  var clock: CartesiaPacingClock {
    CartesiaPacingClock(
      now: { self.now },
      sleep: { deadline in
        self.sleeps.append(self.now.duration(to: deadline))
        self.now = deadline
      })
  }

  func advance(by duration: Duration) { now = now.advanced(by: duration) }
}

@MainActor
private final class CartesiaTransportSpy: CartesiaWebSocketTransport {
  enum OpenBehavior {
    case succeeds
    case fails(Error)
    case hangs
  }

  typealias Message = URLSessionWebSocketTask.Message

  var openBehavior = OpenBehavior.succeeds
  /// What the server sends after it receives a text command.
  var replies: [String: [Result<Message, Error>]] = [:]
  var sendFailure: Error?
  private(set) var openCount = 0
  private(set) var sentMessages: [Message] = []
  private(set) var cancelCodes: [URLSessionWebSocketTask.CloseCode] = []
  private var queued: [Result<Message, Error>] = []
  private var pendingReceive: CheckedContinuation<Message, Error>?
  private var pendingOpen: CheckedContinuation<Void, Error>?

  var sentText: [String] {
    sentMessages.compactMap {
      if case .string(let text) = $0 { return text }
      return nil
    }
  }

  var sentData: [Data] {
    sentMessages.compactMap {
      if case .data(let data) = $0 { return data }
      return nil
    }
  }

  func open() async throws {
    openCount += 1
    switch openBehavior {
    case .succeeds: return
    case .fails(let error): throw error
    case .hangs: try await withCheckedThrowingContinuation { pendingOpen = $0 }
    }
  }

  func send(_ message: Message) async throws {
    if let sendFailure { throw sendFailure }
    sentMessages.append(message)
    if case .string(let text) = message {
      for reply in replies[text] ?? [] { enqueue(reply) }
    }
  }

  func receive() async throws -> Message {
    if !queued.isEmpty { return try queued.removeFirst().get() }
    return try await withCheckedThrowingContinuation { pendingReceive = $0 }
  }

  func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
    cancelCodes.append(closeCode)
    pendingOpen?.resume(throwing: CancellationError())
    pendingOpen = nil
    pendingReceive?.resume(throwing: CancellationError())
    pendingReceive = nil
  }

  func serverSends(_ json: String) { enqueue(.success(.string(json))) }

  private func enqueue(_ result: Result<Message, Error>) {
    if let pendingReceive {
      self.pendingReceive = nil
      pendingReceive.resume(with: result)
    } else {
      queued.append(result)
    }
  }
}

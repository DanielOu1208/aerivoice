import Foundation
import XCTest
@testable import AeriVoice

@MainActor
final class GrokRealtimeClientTests: XCTestCase {
  private func connect(_ client: GrokRealtimeClient) async throws {
    try await client.connect(configuration: TranscriptionConfiguration(provider: .grok),
      apiKey: "test-key", vocabulary: ["AeriVoice"], sessionID: DictationSessionID())
  }

  func testHundredMillisecondPacketsPreserveAllBytesAndFlushOnlyOnce() async throws {
    let socket = GrokTestSocket()
    let time = GrokTestClock()
    let client = GrokRealtimeClient(packetPolicy: .milliseconds100, clock: time.clock, makeTransport: { _ in socket })
    var counts: [Int] = []
    client.onAudioSent = { counts.append($0) }
    try await connect(client)
    let bytes = Data((0..<7_777).map { UInt8($0 % 251) })
    for range in [0..<901, 901..<4_200, 4_200..<7_777] {
      try await client.send(RealtimeAudioFrame(audio: bytes.subdata(in: range), queuedBytesAfterFrame: 0))
    }
    XCTAssertEqual(socket.binaryFrames.map(\.count), [3_200, 3_200])
    try await client.flushAudio()
    try await client.flushAudio()
    _ = try await client.finish()
    XCTAssertEqual(socket.binaryFrames.reduce(Data(), +), bytes)
    XCTAssertEqual(counts, [3_200, 3_200, 1_377])
    XCTAssertEqual(socket.sent, [#"{"type":"audio.done"}"#])
  }

  func testDirectFinishFlushesShortTailBeforeDone() async throws {
    let socket = GrokTestSocket()
    let client = GrokRealtimeClient(packetPolicy: .milliseconds100, makeTransport: { _ in socket })
    try await connect(client)
    try await client.send(RealtimeAudioFrame(audio: Data([1, 2, 3, 4]), queuedBytesAfterFrame: 0))
    XCTAssertTrue(socket.binaryFrames.isEmpty)
    _ = try await client.finish()
    XCTAssertEqual(socket.operations, ["audio:4", "done"])
  }

  func testCumulativePacingCompensatesSmallOversleeps() async throws {
    let socket = GrokTestSocket()
    let time = GrokTestClock()
    time.oversleep = .milliseconds(10)
    let client = GrokRealtimeClient(packetPolicy: .captureFrames, clock: time.clock, makeTransport: { _ in socket })
    socket.onBinary = { time.sendTimes.append(time.current) }
    try await connect(client)
    for _ in 0..<10 {
      try await client.send(RealtimeAudioFrame(audio: Data(repeating: 7, count: 3_200), queuedBytesAfterFrame: 0))
    }
    XCTAssertEqual(time.origin.duration(to: try XCTUnwrap(time.sendTimes.last)), .milliseconds(910))
    XCTAssertEqual(time.deadlines.last, time.origin.advanced(by: .milliseconds(900)))
    client.cancel()
  }

  func testFullIntervalStallRebasesWithoutCatchUpBurst() async throws {
    let socket = GrokTestSocket()
    let time = GrokTestClock()
    let client = GrokRealtimeClient(packetPolicy: .captureFrames, clock: time.clock, makeTransport: { _ in socket })
    socket.onBinary = { time.sendTimes.append(time.current) }
    try await connect(client)
    try await client.send(RealtimeAudioFrame(audio: Data(repeating: 0, count: 3_200), queuedBytesAfterFrame: 0))
    time.oversleep = .milliseconds(250)
    try await client.send(RealtimeAudioFrame(audio: Data(repeating: 0, count: 3_200), queuedBytesAfterFrame: 0))
    time.oversleep = .zero
    try await client.send(RealtimeAudioFrame(audio: Data(repeating: 0, count: 3_200), queuedBytesAfterFrame: 0))
    XCTAssertEqual(time.sendTimes.map { time.origin.duration(to: $0) }, [.zero, .milliseconds(350), .milliseconds(450)])
    client.cancel()
  }

  func testQueuedAudioCatchesUpWithoutChangingBytesThenResumesRealtime() async throws {
    let socket = GrokTestSocket()
    let time = GrokTestClock()
    let client = GrokRealtimeClient(clock: time.clock, makeTransport: { _ in socket })
    socket.onBinary = { time.sendTimes.append(time.current) }
    try await connect(client)
    let frames = [
      RealtimeAudioFrame(audio: Data(repeating: 1, count: 640), queuedBytesAfterFrame: 642),
      RealtimeAudioFrame(audio: Data(repeating: 2, count: 640), queuedBytesAfterFrame: 2),
      RealtimeAudioFrame(audio: Data([3, 4]), queuedBytesAfterFrame: 0),
      RealtimeAudioFrame(audio: Data(repeating: 5, count: 640), queuedBytesAfterFrame: 0),
      RealtimeAudioFrame(audio: Data(repeating: 6, count: 640), queuedBytesAfterFrame: 0),
    ]
    for frame in frames { try await client.send(frame) }
    XCTAssertEqual(socket.binaryFrames, frames.map(\.audio))
    assertSendIntervals(time.sendTimes, seconds: [0.02 / 1.35, 0.02 / 1.35, 2.0 / 32_000, 0.02])
    client.cancel()
  }

  func testBufferedPacketsCountTheirOwnBacklogAndFlushEveryByte() async throws {
    let socket = GrokTestSocket()
    let time = GrokTestClock()
    let client = GrokRealtimeClient(packetPolicy: .milliseconds100,
      clock: time.clock, makeTransport: { _ in socket })
    socket.onBinary = { time.sendTimes.append(time.current) }
    try await connect(client)
    let first = Data((0..<9_600).map { UInt8($0 % 251) })
    let last = Data(repeating: 8, count: 3_202)
    try await client.send(RealtimeAudioFrame(audio: first, queuedBytesAfterFrame: 0))
    try await client.send(RealtimeAudioFrame(audio: last, queuedBytesAfterFrame: 0))
    try await client.flushAudio()
    _ = try await client.finish()
    XCTAssertEqual(socket.binaryFrames.reduce(Data(), +), first + last)
    XCTAssertEqual(socket.binaryFrames.map(\.count), [3_200, 3_200, 3_200, 3_200, 2])
    assertSendIntervals(time.sendTimes, seconds: [0.1 / 1.35, 0.1 / 1.35, 0.1, 0.1 / 1.35])
    XCTAssertEqual(socket.operations.last, "done")
  }

  func testCatchUpRebasesAfterStallAndDoesNotBurst() async throws {
    let socket = GrokTestSocket()
    let time = GrokTestClock()
    let client = GrokRealtimeClient(clock: time.clock, makeTransport: { _ in socket })
    socket.onBinary = { time.sendTimes.append(time.current) }
    try await connect(client)
    let bytes = Data(repeating: 7, count: 3_200)
    try await client.send(RealtimeAudioFrame(audio: bytes, queuedBytesAfterFrame: 6_400))
    time.advance(by: .milliseconds(250))
    for remaining in [3_200, 0, 0] {
      try await client.send(RealtimeAudioFrame(audio: bytes, queuedBytesAfterFrame: remaining))
    }
    assertSendIntervals(time.sendTimes, seconds: [0.25, 0.1 / 1.35, 0.1])
    XCTAssertEqual(socket.binaryFrames, Array(repeating: bytes, count: 4))
    client.cancel()
  }

  private func assertSendIntervals(_ times: [ContinuousClock.Instant], seconds: [Double],
                                  file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(times.count, seconds.count + 1, file: file, line: line)
    for (pair, expected) in zip(zip(times, times.dropFirst()), seconds) {
      let duration = pair.0.duration(to: pair.1).components
      let actual = Double(duration.seconds) + Double(duration.attoseconds) / 1e18
      XCTAssertEqual(actual, expected, accuracy: 0.000_001, file: file, line: line)
    }
  }

  func testPreparedConnectionAdoptsWithoutReconnectAndHasNoIdleWrites() async throws {
    let socket = GrokTestSocket()
    var constructions = 0
    let client = GrokRealtimeClient(makeTransport: { _ in constructions += 1; return socket })
    var events: [String] = []
    client.onConnectionEvent = { events.append($0) }
    let prepared = await client.prepareConnection(configuration: .init(provider: .grok),
      apiKey: "test-key", vocabulary: [" AeriVoice ", "aerivoice"])
    XCTAssertTrue(prepared)
    XCTAssertTrue(client.hasPreparedConnection)
    XCTAssertTrue(socket.binaryFrames.isEmpty)
    XCTAssertTrue(socket.sent.isEmpty)
    client.cancelActiveConnection()
    XCTAssertTrue(client.hasPreparedConnection)
    try await connect(client)
    XCTAssertFalse(client.hasPreparedConnection)
    XCTAssertEqual(constructions, 1)
    XCTAssertEqual(events, ["preparationStarted", "preparationReady", "preparationHit"])
    try await client.send(RealtimeAudioFrame(audio: Data([8, 9]), queuedBytesAfterFrame: 0))
    _ = try await client.finish()
    XCTAssertEqual(socket.binaryFrames, [Data([8, 9])])
    XCTAssertTrue(events.contains("audioDoneSent"))
  }

  func testPreparedMismatchClosesOldSocketAndConnectsFresh() async throws {
    let old = GrokTestSocket()
    let next = GrokTestSocket()
    var sockets = [old, next]
    let client = GrokRealtimeClient(makeTransport: { _ in sockets.removeFirst() })
    _ = await client.prepareConnection(configuration: .init(provider: .grok), apiKey: "other-key", vocabulary: ["AeriVoice"])
    try await connect(client)
    XCTAssertTrue(old.cancelled)
    XCTAssertEqual(sockets.count, 0)
    _ = try await client.finish()
  }

  func testRepeatedPreparationDoesNotExtendExpiry() async throws {
    let socket = GrokTestSocket()
    let time = GrokTestClock()
    let client = GrokRealtimeClient(clock: time.clock, makeTransport: { _ in socket })
    var events: [String] = []
    client.onConnectionEvent = { events.append($0) }
    _ = await client.prepareConnection(configuration: .init(provider: .grok), apiKey: "test-key", vocabulary: [])
    time.advance(by: .seconds(20))
    let repeated = await client.prepareConnection(configuration: .init(provider: .grok), apiKey: "test-key", vocabulary: [])
    XCTAssertTrue(repeated)
    time.advance(by: .seconds(10))
    while !socket.cancelled { await Task.yield() }
    XCTAssertFalse(client.hasPreparedConnection)
    XCTAssertEqual(events.filter { $0 == "preparationStarted" }.count, 1)
    XCTAssertTrue(events.contains("preparationExpired"))
  }

  func testIdleFailureIsQuietAndDoesNotPoisonFreshConnection() async throws {
    let old = GrokTestSocket()
    let next = GrokTestSocket()
    var sockets = [old, next]
    let client = GrokRealtimeClient(makeTransport: { _ in sockets.removeFirst() })
    client.onError = { _ in XCTFail("Idle error reached dictation UI") }
    _ = await client.prepareConnection(configuration: .init(provider: .grok), apiKey: "test-key", vocabulary: ["AeriVoice"])
    old.push(#"{"type":"error","message":"private"}"#)
    while client.hasPreparedConnection { await Task.yield() }
    try await connect(client)
    _ = try await client.finish()
  }

  func testConnectingPreparationIsCancelledRatherThanAdopted() async throws {
    let old = GrokTestSocket(greeting: false)
    let next = GrokTestSocket()
    var sockets = [old, next]
    let client = GrokRealtimeClient(makeTransport: { _ in sockets.removeFirst() })
    let preparation = Task { await client.prepareConnection(configuration: .init(provider: .grok), apiKey: "test-key", vocabulary: ["AeriVoice"]) }
    await old.waitUntilReceiving()
    try await connect(client)
    let result = await preparation.value
    XCTAssertFalse(result)
    XCTAssertTrue(old.cancelled)
    old.push(#"{"type":"error"}"#)
    _ = try await client.finish()
  }

  func testFailedAudioWriteIsNotReplayedAndNewSessionDropsBufferedTail() async throws {
    let old = GrokTestSocket()
    old.failBinary = true
    let next = GrokTestSocket()
    var sockets = [old, next]
    let client = GrokRealtimeClient(packetPolicy: .milliseconds100, makeTransport: { _ in sockets.removeFirst() })
    var sent = 0
    client.onAudioSent = { sent += $0 }
    try await connect(client)
    do {
      try await client.send(RealtimeAudioFrame(audio: Data(repeating: 4, count: 3_300), queuedBytesAfterFrame: 0))
      XCTFail("Expected write failure")
    } catch {}
    XCTAssertEqual(sent, 0)
    XCTAssertEqual(old.binaryAttempts, 1)
    XCTAssertTrue(old.cancelled)
    try await connect(client)
    _ = try await client.finish()
    XCTAssertTrue(next.binaryFrames.isEmpty)
  }

  func testCancelledPacingCannotWriteToReconnectedSession() async throws {
    let old = GrokTestSocket()
    let next = GrokTestSocket()
    let time = GrokTestClock()
    var sockets = [old, next]
    let client = GrokRealtimeClient(packetPolicy: .captureFrames, clock: time.clock,
      makeTransport: { _ in sockets.removeFirst() })
    try await connect(client)
    let frame = RealtimeAudioFrame(audio: Data(repeating: 1, count: 3_200), queuedBytesAfterFrame: 0)
    try await client.send(frame)
    time.pausePacing = true
    let pending = Task { try await client.send(frame) }
    while time.waiterCount == 0 { await Task.yield() }
    client.cancelActiveConnection()
    try await connect(client)
    time.advance(by: .milliseconds(100))
    do { try await pending.value; XCTFail("Expected obsolete sender cancellation") }
    catch { XCTAssertTrue(error is CancellationError) }
    XCTAssertEqual(old.binaryAttempts, 1)
    XCTAssertTrue(next.binaryFrames.isEmpty)
    client.cancel()
  }

  func testAdoptionCancelsExpiryAndResetsFirstAudioTimeline() async throws {
    let socket = GrokTestSocket()
    let time = GrokTestClock()
    let client = GrokRealtimeClient(packetPolicy: .captureFrames, clock: time.clock, makeTransport: { _ in socket })
    socket.onBinary = { time.sendTimes.append(time.current) }
    _ = await client.prepareConnection(configuration: .init(provider: .grok), apiKey: "test-key", vocabulary: ["AeriVoice"])
    time.advance(by: .seconds(29))
    try await connect(client)
    time.advance(by: .seconds(2))
    await Task.yield()
    XCTAssertFalse(socket.cancelled)
    try await client.send(RealtimeAudioFrame(audio: Data([1, 2]), queuedBytesAfterFrame: 0))
    XCTAssertTrue(time.deadlines.isEmpty)
    XCTAssertEqual(time.sendTimes, [time.origin.advanced(by: .seconds(31))])
    client.cancel()
  }

  func testPreparationFailureReturnsFalseWithoutErrorCallback() async {
    let socket = GrokTestSocket(greeting: false)
    socket.push("malformed private data")
    let client = GrokRealtimeClient(makeTransport: { _ in socket })
    client.onError = { _ in XCTFail("Preparation error reached UI") }
    let result = await client.prepareConnection(configuration: .init(provider: .grok), apiKey: "test-key", vocabulary: [])
    XCTAssertFalse(result)
    XCTAssertFalse(client.hasPreparedConnection)
    XCTAssertTrue(socket.cancelled)
  }

  func testPreparationTTLStartsAfterHandshakeCompletes() async throws {
    let socket = GrokTestSocket(greeting: false)
    let time = GrokTestClock()
    let client = GrokRealtimeClient(clock: time.clock, makeTransport: { _ in socket })
    let preparation = Task { await client.prepareConnection(configuration: .init(provider: .grok), apiKey: "test-key", vocabulary: []) }
    await socket.waitUntilReceiving()
    time.advance(by: .seconds(2))
    socket.push(#"{"type":"transcript.created"}"#)
    let result = await preparation.value
    XCTAssertTrue(result)
    time.advance(by: .seconds(29))
    XCTAssertTrue(client.hasPreparedConnection)
    XCTAssertFalse(socket.cancelled)
    time.advance(by: .seconds(1))
    while !socket.cancelled { await Task.yield() }
    XCTAssertFalse(client.hasPreparedConnection)
  }

  func testUnexpectedStandbyTranscriptDiscardsWithoutPublishingText() async {
    let socket = GrokTestSocket()
    let client = GrokRealtimeClient(makeTransport: { _ in socket })
    client.onTranscript = { _ in XCTFail("Standby transcript reached UI") }
    client.onError = { _ in XCTFail("Standby transcript error reached UI") }
    _ = await client.prepareConnection(configuration: .init(provider: .grok), apiKey: "test-key", vocabulary: [])
    socket.push(#"{"type":"transcript.partial","text":"unexpected","start":0,"duration":1,"is_final":true,"speech_final":true}"#)
    while !socket.cancelled { await Task.yield() }
    XCTAssertFalse(client.hasPreparedConnection)
  }

  func testRequestPinsModelAndEncodesDictionaryWithoutKeyInURL() throws {
    let request = GrokRealtimeRequest.make(apiKey: "secret-test", vocabulary: ["A&B + C", "你好", "A&B + C"])
    let url = try XCTUnwrap(request.url)
    let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
    XCTAssertEqual(url.host, "api.x.ai")
    XCTAssertEqual(url.path, "/v1/stt")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret-test")
    XCTAssertFalse(url.absoluteString.contains("secret-test"))
    XCTAssertTrue(url.absoluteString.contains("%2B"))
    XCTAssertFalse(url.absoluteString.contains("+"))
    XCTAssertEqual(items.filter { $0.name == "keyterm" }.compactMap(\.value), ["A&B + C", "你好"])
    XCTAssertEqual(items.first { $0.name == "model" }?.value, "grok-voice-transcribe-2.0")
    XCTAssertEqual(items.first { $0.name == "filler_words" }?.value, "true")
    XCTAssertNil(items.first { $0.name == "language" })
  }

  func testDictionaryLimitsPreserveWholeTermsAndSavedInput() {
    let long = String(repeating: "你", count: 51)
    let boundary = String(repeating: "你", count: 50)
    let source = [" AeriVoice ", "aerivoice", long, boundary] + (0..<100).map { "term\($0)" }
    let result = GrokVocabulary(source)
    XCTAssertEqual(result.terms.count, 100)
    XCTAssertEqual(Array(result.terms.prefix(2)), ["AeriVoice", boundary])
    XCTAssertEqual(result.excluded, [long, "term98", "term99"])
    XCTAssertEqual(source.count, 104)
    XCTAssertEqual(GrokVocabulary([]).terms, [])
    XCTAssertTrue(GrokVocabulary([String(repeating: "e\u{301}", count: 26)]).terms.isEmpty)
  }

  func testAssemblerRevisesChunksAndReplacesStitchedUtteranceWithoutDuplication() throws {
    var assembler = GrokTranscriptAssembler()
    func event(_ text: String, _ start: Double, _ duration: Double, _ final: Bool, _ speech: Bool = false) -> GrokRealtimeResponse {
      GrokRealtimeResponse(type: "transcript.partial", text: text, start: start, duration: duration,
        isFinal: final, speechFinal: speech)
    }
    _ = try assembler.consume(event("hello", 0, 1, true))
    _ = try assembler.consume(event("wor", 1, 1, false))
    XCTAssertEqual(try assembler.consume(event("world", 1, 1, false)).snapshot.displayText, "hello world")
    _ = try assembler.consume(event("world", 1, 1, true))
    XCTAssertEqual(try assembler.consume(event("Hello world.", 0, 2, true, true)).snapshot.displayText, "Hello world.")
    XCTAssertEqual(try assembler.consume(event("Hello world.", 2, 2, true, true)).snapshot.displayText, "Hello world. Hello world.")
  }

  func testLiveChunkFinalsWithCumulativeTimestampsKeepEarlierWords() throws {
    var assembler = GrokTranscriptAssembler()
    func event(_ text: String, _ start: Double, _ duration: Double, _ final: Bool, _ speech: Bool = false) -> GrokRealtimeResponse {
      GrokRealtimeResponse(type: "transcript.partial", text: text, start: start, duration: duration,
        isFinal: final, speechFinal: speech)
    }
    _ = try assembler.consume(event("Thanks, that work.", 0.001, 0.899, false))
    _ = try assembler.consume(event("Thanks, that works for me.", 0.001, 1.899, true))
    _ = try assembler.consume(event("See you at three.", 1.9, 0.895, false))
    let full = "Thanks, that works for me. See you at three."
    let chunk = event("See you at three.", 0.001, 2.794, true)
    XCTAssertEqual(try assembler.consume(chunk).snapshot.displayText, full)
    XCTAssertEqual(try assembler.consume(chunk).snapshot.displayText, full)
    XCTAssertEqual(assembler.confirmedText, full)
    XCTAssertEqual(try assembler.consume(event(full, 0.001, 2.794, true, true)).snapshot.displayText, full)
    XCTAssertEqual(try assembler.consume(event(full, 2.795, 2.794, true, true)).snapshot.displayText, full + " " + full)
  }

  func testAdjacentFractionalChunksPreserveTextAndUnicodeWordSpacing() throws {
    for (first, second) in [("café", "con leche"), ("Привет", "мир"), ("مرحبا", "بالعالم")] {
      var assembler = GrokTranscriptAssembler()
      _ = try assembler.consume(GrokRealtimeResponse(type: "transcript.partial", text: first,
        start: 0.1, duration: 0.2, isFinal: true, speechFinal: false))
      let update = try assembler.consume(GrokRealtimeResponse(type: "transcript.partial", text: second,
        start: 0.3, duration: 0.2, isFinal: true, speechFinal: false))
      XCTAssertEqual(update.snapshot.displayText, first + " " + second)
    }
  }

  func testAssemblerDoesNotInsertSpacesInsideChinese() throws {
    var assembler = GrokTranscriptAssembler()
    _ = try assembler.consume(GrokRealtimeResponse(type: "transcript.partial", text: "你好", start: 0, duration: 1, isFinal: true, speechFinal: false))
    let update = try assembler.consume(GrokRealtimeResponse(type: "transcript.partial", text: "世界", start: 1, duration: 1, isFinal: false, speechFinal: false))
    XCTAssertEqual(update.snapshot.displayText, "你好世界")
  }

  func testWaitsForReadyThenSendsBinaryAndUsesAuthoritativeFinal() async throws {
    let socket = GrokTestSocket(greeting: false)
    let client = GrokRealtimeClient(makeTransport: { _ in socket })
    var updates: [String] = []
    client.onTranscript = { updates.append($0.snapshot.displayText) }
    var connected = false
    let connection = Task { try await self.connect(client); connected = true }
    await socket.waitUntilReceiving()
    XCTAssertFalse(connected)
    XCTAssertTrue(socket.sent.isEmpty)
    socket.push(#"{"type":"transcript.created"}"#)
    try await connection.value
    try await client.send(RealtimeAudioFrame(audio: Data([1, 2]), queuedBytesAfterFrame: 0))
    socket.push(#"{"type":"transcript.partial","text":"draft","start":0,"duration":1,"is_final":false,"speech_final":false}"#)
    socket.finalText = "Correct final."
    let result = try await client.finish()
    XCTAssertEqual(result, "Correct final.")
    XCTAssertEqual(updates.last, "Correct final.")
    XCTAssertEqual(socket.binaryFrames, [Data([1, 2])])
    XCTAssertEqual(socket.sent.last, #"{"type":"audio.done"}"#)
    XCTAssertTrue(socket.cancelled)
  }

  func testMissingReadyTimesOutAndClosesTransport() async {
    let socket = GrokTestSocket(greeting: false)
    let client = GrokRealtimeClient(connectionTimeout: .milliseconds(10), makeTransport: { _ in socket })
    do { try await connect(client); XCTFail("Expected timeout") }
    catch { XCTAssertEqual(error.localizedDescription, AppError.connectionTimeout.localizedDescription) }
    XCTAssertTrue(socket.cancelled)
  }

  func testMissingFinalTimesOutRatherThanReturningProvisionalText() async throws {
    let socket = GrokTestSocket()
    socket.finalText = nil
    let client = GrokRealtimeClient(finalizationTimeout: .milliseconds(10), makeTransport: { _ in socket })
    try await connect(client)
    socket.push(#"{"type":"transcript.partial","text":"draft","start":0,"duration":1,"is_final":false,"speech_final":false}"#)
    do { _ = try await client.finish(); XCTFail("Expected timeout") }
    catch { XCTAssertEqual(error.localizedDescription, AppError.finalizeTimeout.localizedDescription) }
    XCTAssertTrue(socket.cancelled)
  }

  func testEmptyDoneAcknowledgementKeepsFinalizedUtterances() async throws {
    let socket = GrokTestSocket()
    socket.finalText = ""
    let client = GrokRealtimeClient(makeTransport: { _ in socket })
    try await connect(client)
    socket.push(#"{"type":"transcript.partial","text":"Hello.","start":0,"duration":1,"is_final":true,"speech_final":true}"#)
    socket.push(#"{"type":"transcript.partial","text":"Again.","start":1,"duration":1,"is_final":true,"speech_final":true}"#)
    socket.push(#"{"type":"transcript.partial","text":"unfinished","start":2,"duration":1,"is_final":false,"speech_final":false}"#)
    let final = try await client.finish()
    XCTAssertEqual(final, "Hello. Again.")
  }

  func testEmptyDoneNeverPromotesUnfinalizedInterimText() async throws {
    let socket = GrokTestSocket()
    socket.finalText = ""
    let client = GrokRealtimeClient(makeTransport: { _ in socket })
    try await connect(client)
    socket.push(#"{"type":"transcript.partial","text":"unfinished","start":0,"duration":1,"is_final":false,"speech_final":false}"#)
    do { _ = try await client.finish(); XCTFail("Expected empty transcript") }
    catch { XCTAssertEqual(error.localizedDescription, AppError.emptyTranscript.localizedDescription) }
  }

  func testSilenceFinalIsEmptyTranscript() async throws {
    let socket = GrokTestSocket()
    socket.finalText = "  "
    let client = GrokRealtimeClient(makeTransport: { _ in socket })
    try await connect(client)
    do { _ = try await client.finish(); XCTFail("Expected empty") }
    catch { XCTAssertEqual(error.localizedDescription, AppError.emptyTranscript.localizedDescription) }
  }

  func testCancelConnectAndReconnectIgnoresOldResponse() async throws {
    let old = GrokTestSocket(greeting: false)
    let next = GrokTestSocket()
    var sockets = [old, next]
    let client = GrokRealtimeClient(makeTransport: { _ in sockets.removeFirst() })
    let pending = Task { try await self.connect(client) }
    await old.waitUntilReceiving()
    client.cancel()
    try await connect(client)
    old.push(#"{"type":"transcript.created"}"#)
    do { try await pending.value; XCTFail("Expected cancellation") }
    catch { XCTAssertTrue(error is CancellationError) }
    let final = try await client.finish()
    XCTAssertEqual(final, "Final text.")
  }

  func testTaskCancellationWhileFinishingClosesSession() async throws {
    let socket = GrokTestSocket()
    socket.finalText = nil
    let client = GrokRealtimeClient(makeTransport: { _ in socket })
    try await connect(client)
    let finishing = Task { try await client.finish() }
    while !socket.sent.contains(#"{"type":"audio.done"}"#) { await Task.yield() }
    finishing.cancel()
    do { _ = try await finishing.value; XCTFail("Expected cancellation") }
    catch { XCTAssertTrue(error is CancellationError) }
    XCTAssertTrue(socket.cancelled)
  }

  func testMalformedEventFailsWithoutLeakingContents() async throws {
    let socket = GrokTestSocket()
    let client = GrokRealtimeClient(makeTransport: { _ in socket })
    let failed = expectation(description: "provider failure")
    client.onError = { error in
      XCTAssertFalse(error.localizedDescription.contains("private-dictionary"))
      failed.fulfill()
    }
    try await connect(client)
    socket.push("private-dictionary: invalid json")
    await fulfillment(of: [failed], timeout: 1)
    XCTAssertTrue(socket.cancelled)
  }

  func testProviderErrorDoesNotEchoSensitiveMessage() async throws {
    let socket = GrokTestSocket()
    let client = GrokRealtimeClient(makeTransport: { _ in socket })
    let failed = expectation(description: "provider error")
    client.onError = { error in
      XCTAssertFalse(error.localizedDescription.contains("secret"))
      failed.fulfill()
    }
    try await connect(client)
    socket.push(#"{"type":"error","message":"secret key and terms"}"#)
    await fulfillment(of: [failed], timeout: 1)
  }

  func testTransportAuthenticationAndRateLimitMessagesAreSafe() {
    XCTAssertTrue(GrokTransportError(status: 401).localizedDescription.contains("API key"))
    XCTAssertTrue(GrokTransportError(status: 429).localizedDescription.contains("rate limited"))
  }

  func testOfflinePolicyBlocksBeforeCreatingTransport() async {
    await AppNetworkPolicy.shared.setOffline(true)
    let client = GrokRealtimeClient(makeTransport: { _ in
      XCTFail("Offline connection constructed a socket")
      return GrokTestSocket()
    })
    do { try await connect(client); XCTFail("Expected offline") }
    catch { XCTAssertTrue(error is AppNetworkPolicy.PolicyError) }
    await AppNetworkPolicy.shared.setOffline(false)
  }
}

@MainActor
private final class GrokTestSocket: GrokWebSocketTransport {
  var finalText: String? = "Final text."
  var sent: [String] = []
  var binaryFrames: [Data] = []
  var cancelled = false
  var failBinary = false
  var binaryAttempts = 0
  var operations: [String] = []
  var onBinary: (() -> Void)?
  private var messages: [URLSessionWebSocketTask.Message] = []
  private var waiter: CheckedContinuation<URLSessionWebSocketTask.Message, Error>?

  init(greeting: Bool = true) {
    if greeting { messages.append(.string(#"{"type":"transcript.created"}"#)) }
  }
  func resume() {}
  func send(_ message: URLSessionWebSocketTask.Message) async throws {
    switch message {
    case .data(let bytes):
      binaryAttempts += 1
      if failBinary { throw GrokTransportError(status: nil) }
      binaryFrames.append(bytes)
      operations.append("audio:\(bytes.count)")
      onBinary?()
    case .string(let string):
      sent.append(string)
      operations.append("done")
      if string == #"{"type":"audio.done"}"#, let finalText {
        let data = try JSONSerialization.data(withJSONObject: ["type": "transcript.done", "text": finalText])
        push(String(decoding: data, as: UTF8.self))
      }
    @unknown default: break
    }
  }
  func receive() async throws -> URLSessionWebSocketTask.Message {
    if !messages.isEmpty { return messages.removeFirst() }
    if cancelled { throw CancellationError() }
    return try await withCheckedThrowingContinuation { waiter = $0 }
  }
  func push(_ text: String) {
    if let waiter {
      self.waiter = nil
      waiter.resume(returning: .string(text))
    } else { messages.append(.string(text)) }
  }
  func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
    cancelled = true
    let pending = waiter
    waiter = nil
    pending?.resume(throwing: CancellationError())
  }
  func waitUntilReceiving() async {
    while waiter == nil { await Task.yield() }
  }
}

@MainActor
private final class GrokTestClock {
  let origin = ContinuousClock.now
  var current: ContinuousClock.Instant
  var oversleep: Duration = .zero
  var pausePacing = false
  var waiterCount: Int { expiryWaiters.count }
  var deadlines: [ContinuousClock.Instant] = []
  var sendTimes: [ContinuousClock.Instant] = []
  private var expiryWaiters: [UUID: (ContinuousClock.Instant, CheckedContinuation<Void, Error>)] = [:]

  init() { current = origin }

  var clock: GrokRealtimeClock {
    GrokRealtimeClock(now: { self.current }, sleep: { deadline in
      try Task.checkCancellation()
      if !self.pausePacing && self.current.duration(to: deadline) < .seconds(1) {
        self.deadlines.append(deadline)
        self.current = max(self.current, deadline).advanced(by: self.oversleep)
        return
      }
      let id = UUID()
      try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
          self.expiryWaiters[id] = (deadline, continuation)
        }
      } onCancel: {
        Task { @MainActor in
          self.expiryWaiters.removeValue(forKey: id)?.1.resume(throwing: CancellationError())
        }
      }
    })
  }

  func advance(by duration: Duration) {
    current = current.advanced(by: duration)
    for (id, waiter) in expiryWaiters where waiter.0 <= current {
      expiryWaiters.removeValue(forKey: id)
      waiter.1.resume()
    }
  }
}

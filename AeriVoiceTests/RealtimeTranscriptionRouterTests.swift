import Foundation
import XCTest

@testable import AeriVoice

@MainActor
final class RealtimeTranscriptionRouterTests: XCTestCase {
  func testRoutesMetaSessionWithoutConnectingSoniox() async throws {
    let soniox = RouterClientSpy()
    let meta = RouterClientSpy()
    let router = RealtimeTranscriptionRouter(soniox: soniox, meta: meta)
    let configuration = TranscriptionConfiguration(provider: .meta)
    let sessionID = DictationSessionID()

    try await router.connect(
      configuration: configuration, apiKey: "meta-key", vocabulary: ["Muse"],
      sessionID: sessionID)
    try await router.send(
      RealtimeAudioFrame(audio: Data([1, 2, 3]), queuedBytesAfterFrame: 6_400))
    meta.finishResult = "Meta transcript"
    let transcript = try await router.finish()

    XCTAssertEqual(transcript, "Meta transcript")
    XCTAssertEqual(meta.connection?.configuration, configuration)
    XCTAssertEqual(meta.connection?.apiKey, "meta-key")
    XCTAssertEqual(meta.connection?.vocabulary, ["Muse"])
    XCTAssertEqual(meta.connection?.sessionID, sessionID)
    XCTAssertEqual(meta.sentAudio, [Data([1, 2, 3])])
    XCTAssertEqual(meta.sentFrames.first?.queuedBytesAfterFrame, 6_400)
    XCTAssertNil(soniox.connection)
  }

  func testOnlyActiveProviderCallbacksAreForwarded() async throws {
    let soniox = RouterClientSpy()
    let meta = RouterClientSpy()
    let router = RealtimeTranscriptionRouter(soniox: soniox, meta: meta)
    var updates: [RealtimeTranscriptUpdate] = []
    var errors: [Error] = []
    router.onTranscript = { updates.append($0) }
    router.onError = { errors.append($0) }

    try await router.connect(
      configuration: TranscriptionConfiguration(provider: .meta), apiKey: "meta-key",
      vocabulary: [], sessionID: DictationSessionID())
    let update = RealtimeTranscriptUpdate(
      snapshot: TranscriptSnapshot(provisional: "hello"), hasFinalText: false,
      finalAudioProcessedMS: nil, totalAudioProcessedMS: nil)
    soniox.onTranscript?(update)
    soniox.onError?(AppError.provider("inactive"))
    meta.onTranscript?(update)

    XCTAssertEqual(updates, [update])
    XCTAssertTrue(errors.isEmpty)
  }

  func testFailedMetaConnectionDoesNotFallBackToSoniox() async {
    let soniox = RouterClientSpy()
    let meta = RouterClientSpy()
    meta.connectError = AppError.provider("Meta failed")
    let router = RealtimeTranscriptionRouter(soniox: soniox, meta: meta)

    do {
      try await router.connect(
        configuration: TranscriptionConfiguration(provider: .meta), apiKey: "meta-key",
        vocabulary: [], sessionID: DictationSessionID())
      XCTFail("Expected the selected provider error")
    } catch {
      XCTAssertEqual(error.localizedDescription, "Meta failed")
    }

    XCTAssertNil(soniox.connection)
  }

  func testCancelledMetaConnectCannotClearNewMetaSession() async throws {
    let soniox = RouterClientSpy()
    let meta = ReconnectingRouterClientSpy()
    let router = RealtimeTranscriptionRouter(soniox: soniox, meta: meta)
    let configuration = TranscriptionConfiguration(provider: .meta)

    let oldConnection = Task { @MainActor in
      do {
        try await router.connect(
          configuration: configuration, apiKey: "old-key", vocabulary: [],
          sessionID: DictationSessionID())
        return nil as Error?
      } catch {
        return error
      }
    }
    for _ in 0..<100 where meta.connectionCount == 0 { await Task.yield() }
    XCTAssertEqual(meta.connectionCount, 1)

    try await router.connect(
      configuration: configuration, apiKey: "new-key", vocabulary: [],
      sessionID: DictationSessionID())
    meta.failFirstConnection()
    _ = await oldConnection.value

    let frame = RealtimeAudioFrame(audio: Data([7]), queuedBytesAfterFrame: 0)
    try await router.send(frame)
    XCTAssertEqual(meta.sentFrames, [frame])
    XCTAssertNil(soniox.connection)
  }
}

@MainActor
private final class ReconnectingRouterClientSpy: RealtimeTranscribing {
  var onTranscript: ((RealtimeTranscriptUpdate) -> Void)?
  var onError: ((Error) -> Void)?
  private(set) var connectionCount = 0
  private(set) var sentFrames: [RealtimeAudioFrame] = []
  private var firstConnection: CheckedContinuation<Void, Error>?

  func connect(
    configuration: TranscriptionConfiguration, apiKey: String, vocabulary: [String],
    sessionID: DictationSessionID
  ) async throws {
    connectionCount += 1
    if connectionCount == 1 {
      try await withCheckedThrowingContinuation { firstConnection = $0 }
    }
  }

  func failFirstConnection() {
    firstConnection?.resume(throwing: CancellationError())
    firstConnection = nil
  }

  func send(_ frame: RealtimeAudioFrame) async throws { sentFrames.append(frame) }
  func finish() async throws -> String { "Transcript" }
  func cancel() {}
}

@MainActor
private final class RouterClientSpy: RealtimeTranscribing {
  struct Connection: Equatable {
    let configuration: TranscriptionConfiguration
    let apiKey: String
    let vocabulary: [String]
    let sessionID: DictationSessionID
  }

  var onTranscript: ((RealtimeTranscriptUpdate) -> Void)?
  var onError: ((Error) -> Void)?
  var connection: Connection?
  var connectError: Error?
  var sentFrames: [RealtimeAudioFrame] = []
  var sentAudio: [Data] = []
  var finishResult = "Transcript"
  private(set) var cancelCount = 0

  func connect(
    configuration: TranscriptionConfiguration, apiKey: String, vocabulary: [String],
    sessionID: DictationSessionID
  ) async throws {
    connection = Connection(
      configuration: configuration, apiKey: apiKey, vocabulary: vocabulary, sessionID: sessionID)
    if let connectError { throw connectError }
  }

  func send(_ frame: RealtimeAudioFrame) async throws {
    sentFrames.append(frame)
    sentAudio.append(frame.audio)
  }
  func finish() async throws -> String { finishResult }
  func cancel() { cancelCount += 1 }
}

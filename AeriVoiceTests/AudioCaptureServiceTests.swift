import AVFoundation
import XCTest

@testable import AeriVoice

final class AudioCaptureServiceTests: XCTestCase {
  func testPreparationDoesNotStartCaptureAndIsConsumedOnlyOnce() async throws {
    let fixture = AudioPreparationFixture()
    let service = fixture.service()
    await service.prepare()
    await service.prepare()
    XCTAssertEqual(fixture.engines.count, 1)
    XCTAssertEqual(fixture.engines[0].prepareCount, 1)
    XCTAssertEqual(fixture.engines[0].startCount, 0)

    let reused = try await service.start()
    XCTAssertTrue(reused)
    XCTAssertEqual(fixture.engines.count, 1)
    service.stop()
    let reusedAgain = try await service.start()
    XCTAssertFalse(reusedAgain)
    XCTAssertEqual(fixture.engines.count, 2)
    service.stop()
  }

  func testInputDeviceAndFormatChangesDiscardPreparation() async throws {
    for changedRoute in [
      AudioInputRoute(deviceID: 2, sampleRate: 48_000, channels: 1),
      AudioInputRoute(deviceID: 1, sampleRate: 96_000, channels: 1),
      AudioInputRoute(deviceID: 1, sampleRate: 48_000, channels: 2),
    ] {
      let fixture = AudioPreparationFixture()
      let service = fixture.service()
      await service.prepare()
      let prepared = fixture.engines[0]
      fixture.route = changedRoute
      let reused = try await service.start()
      XCTAssertFalse(reused)
      XCTAssertEqual(prepared.startCount, 0)
      XCTAssertEqual(prepared.stopCount, 1)
      XCTAssertEqual(fixture.engines.count, 2)
      service.stop()
    }
  }

  func testConfigurationNotificationDiscardsOnlyUnusedPreparation() async throws {
    let fixture = AudioPreparationFixture()
    let service = fixture.service()
    await service.prepare()
    NotificationCenter.default.post(
      name: .AVAudioEngineConfigurationChange, object: fixture.engines[0].notificationObject)
    let reused = try await service.start()
    XCTAssertFalse(reused)
    service.stop()

    await service.prepare()
    let prepared = fixture.engines.last!
    _ = try await service.start()
    NotificationCenter.default.post(
      name: .AVAudioEngineConfigurationChange, object: prepared.notificationObject)
    // Preparation is also a queue barrier, and must not change active recording.
    await service.prepare()
    XCTAssertEqual(prepared.stopCount, 0)
    service.stop()
  }

  func testFailedPreparationFallsBackToFreshCapture() async throws {
    let fixture = AudioPreparationFixture { index in
      FakeCaptureAudioEngine(prepareFails: index == 0)
    }
    let service = fixture.service()
    await service.prepare()
    XCTAssertEqual(fixture.engines[0].stopCount, 1)
    let reused = try await service.start()
    XCTAssertFalse(reused)
    XCTAssertEqual(fixture.engines.count, 2)
    service.stop()
  }

  func testActivationDuringPreparationUsesTheSameEngine() async throws {
    let entered = expectation(description: "Preparing")
    let gate = DispatchSemaphore(value: 0)
    let engine = FakeCaptureAudioEngine(prepareEntered: entered, prepareGate: gate)
    let fixture = AudioPreparationFixture { _ in engine }
    let service = fixture.service()
    let preparation = Task { await service.prepare() }
    await fulfillment(of: [entered], timeout: 2)
    let activation = Task { try await service.start() }
    gate.signal()
    await preparation.value
    let reused = try await activation.value
    XCTAssertTrue(reused)
    XCTAssertEqual(fixture.engines.count, 1)
    XCTAssertEqual(engine.prepareCount, 1)
    XCTAssertEqual(engine.startCount, 1)
    service.stop()
  }

  func testDiscardDuringPreparationCannotLeavePreparedResourcesBehind() async throws {
    let entered = expectation(description: "Preparing")
    let gate = DispatchSemaphore(value: 0)
    let prepared = FakeCaptureAudioEngine(prepareEntered: entered, prepareGate: gate)
    let fixture = AudioPreparationFixture { index in
      index == 0 ? prepared : FakeCaptureAudioEngine()
    }
    let service = fixture.service()
    let preparation = Task { await service.prepare() }
    await fulfillment(of: [entered], timeout: 2)
    service.discardPreparation()
    gate.signal()
    await preparation.value
    let reused = try await service.start()
    XCTAssertFalse(reused)
    XCTAssertEqual(prepared.startCount, 0)
    XCTAssertEqual(prepared.stopCount, 1)
    service.stop()
  }

  func testCancelledStartupTearsDownBeforeReturning() async throws {
    let entered = expectation(description: "Starting")
    let gate = DispatchSemaphore(value: 0)
    let engine = FakeCaptureAudioEngine(startEntered: entered, startGate: gate)
    let fixture = AudioPreparationFixture { _ in engine }
    let service = fixture.service()
    let activation = Task { try await service.start() }
    await fulfillment(of: [entered], timeout: 2)
    activation.cancel()
    gate.signal()
    do {
      _ = try await activation.value
      XCTFail("Cancelled audio startup succeeded")
    } catch is CancellationError {
    }
    XCTAssertEqual(engine.startCount, 0)
    XCTAssertEqual(engine.stopCount, 1)
  }

  func testCancelStartReturnsWithoutWaitingAndPreventsHardwareStartup() async throws {
    let entered = expectation(description: "Starting")
    let gate = DispatchSemaphore(value: 0)
    let engine = FakeCaptureAudioEngine(startEntered: entered, startGate: gate)
    let fixture = AudioPreparationFixture { _ in engine }
    let service = fixture.service()
    let activation = Task { try await service.start() }
    await fulfillment(of: [entered], timeout: 2)
    service.cancelStart()
    gate.signal()
    do {
      _ = try await activation.value
      XCTFail("Invalidated audio startup succeeded")
    } catch is CancellationError {
    }
    XCTAssertEqual(engine.startCount, 0)
    XCTAssertEqual(engine.stopCount, 1)
  }

  func testConverterAdaptsFromNinetySixToFortyEightKilohertz() throws {
    let converter = try XCTUnwrap(PCM16AudioConverter())
    let ninetySixKilohertz = try makeBuffer(sampleRate: 96_000, frameCount: 960)
    let fortyEightKilohertz = try makeBuffer(sampleRate: 48_000, frameCount: 480)

    let first = try XCTUnwrap(converter.convert(ninetySixKilohertz))
    let second = try XCTUnwrap(converter.convert(fortyEightKilohertz))

    XCTAssertGreaterThan(first.count, 0)
    XCTAssertGreaterThan(second.count, 0)
    XCTAssertEqual(first.count, second.count, accuracy: 16)
  }

  func testConverterAdaptsFromFortyEightToNinetySixKilohertz() throws {
    let converter = try XCTUnwrap(PCM16AudioConverter())
    let fortyEightKilohertz = try makeBuffer(sampleRate: 48_000, frameCount: 480)
    let ninetySixKilohertz = try makeBuffer(sampleRate: 96_000, frameCount: 960)

    let first = try XCTUnwrap(converter.convert(fortyEightKilohertz))
    let second = try XCTUnwrap(converter.convert(ninetySixKilohertz))

    XCTAssertGreaterThan(first.count, 0)
    XCTAssertGreaterThan(second.count, 0)
    XCTAssertEqual(first.count, second.count, accuracy: 16)
  }

  private func makeBuffer(
    sampleRate: Double, frameCount: AVAudioFrameCount
  ) throws -> AVAudioPCMBuffer {
    let format = try XCTUnwrap(
      AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1,
        interleaved: false))
    let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
    buffer.frameLength = frameCount
    let samples = try XCTUnwrap(buffer.floatChannelData?[0])
    for frame in 0..<Int(frameCount) {
      samples[frame] = sin(Float(frame) * 0.05)
    }
    return buffer
  }
}

private final class AudioPreparationFixture: @unchecked Sendable {
  private let lock = NSLock()
  private var inputRoute = AudioInputRoute(deviceID: 1, sampleRate: 48_000, channels: 1)
  private var created: [FakeCaptureAudioEngine] = []
  private let factory: @Sendable (Int) -> FakeCaptureAudioEngine

  init(
    factory: @escaping @Sendable (Int) -> FakeCaptureAudioEngine = { _ in FakeCaptureAudioEngine() }
  ) {
    self.factory = factory
  }

  var route: AudioInputRoute {
    get { lock.withLock { inputRoute } }
    set { lock.withLock { inputRoute = newValue } }
  }
  var engines: [FakeCaptureAudioEngine] { lock.withLock { created } }

  func service() -> AudioCaptureService {
    AudioCaptureService(
      makeEngine: {
        self.lock.withLock {
          let engine = self.factory(self.created.count)
          self.created.append(engine)
          return engine
        }
      }, currentRoute: { self.route })
  }
}

private final class FakeCaptureAudioEngine: CaptureAudioEngine, @unchecked Sendable {
  private let lock = NSLock()
  private let object = NSObject()
  private let prepareFails: Bool
  private let prepareEntered: XCTestExpectation?
  private let prepareGate: DispatchSemaphore?
  private let startEntered: XCTestExpectation?
  private let startGate: DispatchSemaphore?
  private var preparations = 0
  private var starts = 0
  private var stops = 0

  init(
    prepareFails: Bool = false, prepareEntered: XCTestExpectation? = nil,
    prepareGate: DispatchSemaphore? = nil, startEntered: XCTestExpectation? = nil,
    startGate: DispatchSemaphore? = nil
  ) {
    self.prepareFails = prepareFails
    self.prepareEntered = prepareEntered
    self.prepareGate = prepareGate
    self.startEntered = startEntered
    self.startGate = startGate
  }

  var notificationObject: AnyObject { object }
  var prepareCount: Int { lock.withLock { preparations } }
  var startCount: Int { lock.withLock { starts } }
  var stopCount: Int { lock.withLock { stops } }

  func prepare() throws {
    lock.withLock { preparations += 1 }
    prepareEntered?.fulfill()
    if let prepareGate { XCTAssertEqual(prepareGate.wait(timeout: .now() + 3), .success) }
    if prepareFails { throw AppError.microphoneUnavailable }
  }

  func start(
    checkCancellation: @Sendable () throws -> Void,
    onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void
  ) throws {
    startEntered?.fulfill()
    if let startGate { XCTAssertEqual(startGate.wait(timeout: .now() + 3), .success) }
    try checkCancellation()
    lock.withLock { starts += 1 }
  }

  func stop() { lock.withLock { stops += 1 } }
}

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

    let reused = try await service.start().usedPreparation
    XCTAssertTrue(reused)
    XCTAssertEqual(fixture.engines.count, 1)
    service.stop()
    let reusedAgain = try await service.start().usedPreparation
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
      let reused = try await service.start().usedPreparation
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
    let reused = try await service.start().usedPreparation
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
    let reused = try await service.start().usedPreparation
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
    let reused = try await activation.value.usedPreparation
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
    let reused = try await service.start().usedPreparation
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


  func testConfigurationChangeWhileRecordingRestartsOnTheNewInput() async throws {
    let fixture = AudioPreparationFixture()
    let service = fixture.service()
    let interrupted = LockedFlag()
    service.onCaptureInterrupted = { interrupted.set() }
    _ = try await service.start()
    let first = fixture.engines[0]
    fixture.route = AudioInputRoute(deviceID: 2, sampleRate: 24_000, channels: 1)
    // A burst of notifications is coalesced into one restart.
    for _ in 0..<3 {
      NotificationCenter.default.post(
        name: .AVAudioEngineConfigurationChange, object: first.notificationObject)
    }
    try await waitUntil { fixture.engines.count == 2 && fixture.engines[1].startCount == 1 }
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertEqual(fixture.engines.count, 2)
    XCTAssertEqual(first.stopCount, 1)
    XCTAssertFalse(interrupted.value)

    // Stale notifications from the replaced engine are ignored.
    NotificationCenter.default.post(
      name: .AVAudioEngineConfigurationChange, object: first.notificationObject)
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertEqual(fixture.engines.count, 2)
    service.stop()
    XCTAssertEqual(fixture.engines[1].stopCount, 1)
  }

  func testRunningEngineOnUnchangedRouteIsNotRestarted() async throws {
    let fixture = AudioPreparationFixture()
    let service = fixture.service()
    _ = try await service.start()
    NotificationCenter.default.post(
      name: .AVAudioEngineConfigurationChange, object: fixture.engines[0].notificationObject)
    try await Task.sleep(for: .milliseconds(60))
    XCTAssertEqual(fixture.engines.count, 1)
    XCTAssertEqual(fixture.engines[0].stopCount, 0)
    service.stop()
  }

  func testFailedRestartReportsInterruption() async throws {
    let fixture = AudioPreparationFixture { index in FakeCaptureAudioEngine(startFails: index > 0) }
    let service = fixture.service()
    let interrupted = LockedFlag()
    service.onCaptureInterrupted = { interrupted.set() }
    _ = try await service.start()
    fixture.route = AudioInputRoute(deviceID: 2, sampleRate: 48_000, channels: 1)
    NotificationCenter.default.post(
      name: .AVAudioEngineConfigurationChange, object: fixture.engines[0].notificationObject)
    try await waitUntil { interrupted.value }
    XCTAssertEqual(fixture.engines.count, 2)
    service.stop()
  }

  func testRestartsAreCappedPerRecording() async throws {
    let fixture = AudioPreparationFixture()
    let service = fixture.service()
    let interrupted = LockedFlag()
    service.onCaptureInterrupted = { interrupted.set() }
    _ = try await service.start()
    for device in 2...(AudioCaptureService.maximumRestarts + 2) {
      fixture.route = AudioInputRoute(deviceID: AudioDeviceID(device), sampleRate: 48_000, channels: 1)
      let engine = fixture.engines.last!
      NotificationCenter.default.post(
        name: .AVAudioEngineConfigurationChange, object: engine.notificationObject)
      // The replacement starts only after the service observes it, so the next notification
      // can't be posted before anyone listens for it.
      try await waitUntil {
        interrupted.value
          || (fixture.engines.count == device && fixture.engines[device - 1].startCount == 1)
      }
    }
    XCTAssertTrue(interrupted.value)
    XCTAssertEqual(fixture.engines.count, AudioCaptureService.maximumRestarts + 1)
    service.stop()
  }

  func testUnreadableRouteStillAttemptsTheSystemDefault() async throws {
    let engine = FakeCaptureAudioEngine()
    let service = AudioCaptureService(makeEngine: { route in
      XCTAssertFalse(route.pinned)
      return engine
    }, currentRoute: { nil })
    _ = try await service.start()
    XCTAssertEqual(engine.startCount, 1)
    service.stop()
  }

  func testBluetoothInputIsNotPrepared() async throws {
    let fixture = AudioPreparationFixture()
    fixture.route = AudioInputRoute(
      deviceID: 3, sampleRate: 24_000, channels: 1, isBluetooth: true)
    let service = fixture.service()
    let result = await service.prepareWithDiagnostics()
    XCTAssertEqual(result, .skipped)
    XCTAssertTrue(fixture.engines.isEmpty)
    let reused = try await service.start().usedPreparation
    XCTAssertFalse(reused)
    XCTAssertEqual(fixture.engines.count, 1)
    service.stop()
  }

  func testStartReportsTheEngineStepsAndWhetherPreparationWasUsed() async throws {
    let fixture = AudioPreparationFixture()
    let service = fixture.service()
    await service.prepare()
    let prepared = try await service.start()
    XCTAssertTrue(prepared.usedPreparation)
    XCTAssertEqual(prepared.engine, FakeCaptureAudioEngine.steps)
    XCTAssertEqual(prepared.engineCreation, .zero)
    XCTAssertGreaterThanOrEqual(prepared.queueWait, .zero)
    service.stop()

    let cold = try await service.start()
    XCTAssertFalse(cold.usedPreparation)
    XCTAssertEqual(cold.engine, FakeCaptureAudioEngine.steps)
    XCTAssertEqual(fixture.engines.count, 2)
    service.stop()
  }

  func testStartDecliningBluetoothLeavesTheEngineUntouched() async throws {
    let fixture = AudioPreparationFixture()
    let service = fixture.service()
    await service.prepare()
    let prepared = fixture.engines[0]
    for route in [
      AudioInputRoute(deviceID: 3, sampleRate: 24_000, channels: 1, isBluetooth: true), nil,
    ] {
      fixture.optionalRoute = route
      do {
        _ = try await service.start(discardingAudioBefore: nil, declinesBluetooth: true)
        XCTFail("A start declining Bluetooth started on \(String(describing: route))")
      } catch is AudioStartDeclined {}
      XCTAssertEqual(prepared.stopCount, 0)
      XCTAssertEqual(prepared.startCount, 0)
      XCTAssertEqual(fixture.engines.count, 1)
    }

    // The same input that was prepared starts normally, and the preparation is used.
    fixture.route = AudioInputRoute(deviceID: 1, sampleRate: 48_000, channels: 1)
    let report = try await service.start(discardingAudioBefore: nil, declinesBluetooth: true)
    XCTAssertTrue(report.usedPreparation)
    XCTAssertEqual(prepared.startCount, 1)
    service.stop()
  }

  func testAudioRecordedBeforeTheDeadlineIsDropped() async throws {
    let fixture = AudioPreparationFixture()
    let service = fixture.service()
    let delivered = LockedBytes()
    service.onAudio = { delivered.append($0) }
    _ = try await service.start(discardingAudioBefore: .now.advanced(by: .milliseconds(50)))
    // 100 ms at 48 kHz becomes 1,600 samples; roughly the first 800 are before the deadline.
    fixture.engines[0].emit(try makeBuffer(sampleRate: 48_000, frameCount: 4_800))
    fixture.engines[0].emit(try makeBuffer(sampleRate: 48_000, frameCount: 4_800))
    service.stop()
    let samples = delivered.count / MemoryLayout<Int16>.size
    XCTAssertGreaterThan(samples, 2_200)
    XCTAssertLessThan(samples, 2_500)
  }

  func testStopDeliversAudioHeldByTheConverter() async throws {
    let fixture = AudioPreparationFixture()
    let service = fixture.service()
    let delivered = LockedBytes()
    service.onAudio = { delivered.append($0) }
    _ = try await service.start()
    fixture.engines[0].emit(try makeBuffer(sampleRate: 48_000, frameCount: 4_800))
    await service.prepare()
    let beforeStop = delivered.count
    service.stop()
    XCTAssertGreaterThanOrEqual(delivered.count, beforeStop)
    XCTAssertEqual(delivered.count / MemoryLayout<Int16>.size, 1_600, accuracy: 32)
  }

  // MARK: Ending at the release

  /// 100 ms at 48 kHz, as the hardware tap delivers it; 1,600 samples once converted to 16 kHz.
  private let block: AVAudioFrameCount = 4_800

  private func host(_ base: UInt64, plus milliseconds: Double) -> UInt64 {
    AVAudioTime.hostTime(
      forSeconds: AVAudioTime.seconds(forHostTime: base) + milliseconds / 1_000)
  }

  private func samples(_ bytes: LockedBytes) -> Int { bytes.count / MemoryLayout<Int16>.size }

  /// Starts a release stop and waits until it is waiting for its block.
  private func beginReleaseStop(
    _ service: AudioCaptureService, at release: UInt64
  ) async throws -> Task<Void, Never> {
    let stop = service.beginStop(atHostTime: release)
    let stopping = Task { await stop.wait() }
    try await waitUntil { service.isWaitingForReleaseBlock }
    return stopping
  }

  func testReleaseKeepsOnlyTheAudioBeforeIt() async throws {
    let fixture = AudioPreparationFixture()
    let service = fixture.service()
    let delivered = LockedBytes()
    service.onAudio = { delivered.append($0) }
    _ = try await service.start()
    let start = mach_absolute_time()
    let stopping = try await beginReleaseStop(service, at: host(start, plus: 50))
    XCTAssertEqual(fixture.engines[0].stopCount, 0, "The block holding the release is awaited")
    fixture.engines[0].emit(try makeBuffer(sampleRate: 48_000, frameCount: block), hostTime: start)
    await stopping.value
    XCTAssertEqual(fixture.engines[0].stopCount, 1)
    XCTAssertEqual(samples(delivered), 800, accuracy: 48)
  }

  func testBlocksBeforeTheReleaseAreKeptWholeWhileWaiting() async throws {
    let fixture = AudioPreparationFixture()
    let service = fixture.service()
    let delivered = LockedBytes()
    service.onAudio = { delivered.append($0) }
    _ = try await service.start()
    let start = mach_absolute_time()
    let stopping = try await beginReleaseStop(service, at: host(start, plus: 150))
    fixture.engines[0].emit(try makeBuffer(sampleRate: 48_000, frameCount: block), hostTime: start)
    // The first block ends before the release, so capture keeps waiting.
    XCTAssertTrue(service.isWaitingForReleaseBlock)
    XCTAssertEqual(fixture.engines[0].stopCount, 0)
    fixture.engines[0].emit(
      try makeBuffer(sampleRate: 48_000, frameCount: block), hostTime: host(start, plus: 100))
    await stopping.value
    XCTAssertEqual(fixture.engines[0].stopCount, 1)
    XCTAssertEqual(samples(delivered), 2_400, accuracy: 48)
  }

  func testReleaseBlockAndTheConverterRemainderArriveAsOneDelivery() async throws {
    // Each delivery is a frame the transcriber sends, paced for some providers, before the
    // end of the stream can go out.
    let fixture = AudioPreparationFixture()
    let service = fixture.service()
    let delivered = LockedBytes()
    service.onAudio = { delivered.append($0) }
    _ = try await service.start()
    let start = mach_absolute_time()
    let stopping = try await beginReleaseStop(service, at: host(start, plus: 150))
    fixture.engines[0].emit(try makeBuffer(sampleRate: 48_000, frameCount: block), hostTime: start)
    try await waitUntil { delivered.chunks == 1 }
    fixture.engines[0].emit(
      try makeBuffer(sampleRate: 48_000, frameCount: block), hostTime: host(start, plus: 100))
    await stopping.value
    XCTAssertEqual(delivered.chunks, 2)
    XCTAssertEqual(samples(delivered), 2_400, accuracy: 48)
  }

  func testBlockThatStartsAfterTheReleaseIsDropped() async throws {
    let fixture = AudioPreparationFixture()
    let service = fixture.service()
    let delivered = LockedBytes()
    service.onAudio = { delivered.append($0) }
    _ = try await service.start()
    let release = mach_absolute_time()
    let stopping = try await beginReleaseStop(service, at: release)
    fixture.engines[0].emit(
      try makeBuffer(sampleRate: 48_000, frameCount: block), hostTime: host(release, plus: 10))
    await stopping.value
    XCTAssertEqual(fixture.engines[0].stopCount, 1)
    XCTAssertEqual(samples(delivered), 0)
  }

  func testBlockWithoutATimeIsKeptWholeAndEndsCapture() async throws {
    let fixture = AudioPreparationFixture()
    let service = fixture.service()
    let delivered = LockedBytes()
    service.onAudio = { delivered.append($0) }
    _ = try await service.start()
    let stopping = try await beginReleaseStop(service, at: mach_absolute_time())
    fixture.engines[0].emit(try makeBuffer(sampleRate: 48_000, frameCount: block), hostTime: nil)
    await stopping.value
    XCTAssertEqual(fixture.engines[0].stopCount, 1)
    XCTAssertEqual(samples(delivered), 1_600, accuracy: 32)
  }

  func testReleaseStopGivesUpWhenNoBlockArrives() async throws {
    let fixture = AudioPreparationFixture()
    let service = fixture.service(releaseBlockTimeout: .milliseconds(100))
    _ = try await service.start()
    let started = ContinuousClock.now
    await service.beginStop(atHostTime: mach_absolute_time()).wait()
    XCTAssertEqual(fixture.engines[0].stopCount, 1)
    XCTAssertLessThan(started.duration(to: .now), .seconds(3))
  }

  func testStopDuringAReleaseWaitEndsItAtOnce() async throws {
    let fixture = AudioPreparationFixture()
    let service = fixture.service()
    _ = try await service.start()
    let stopping = try await beginReleaseStop(service, at: host(mach_absolute_time(), plus: 500))
    let stopped = ContinuousClock.now
    service.stop()
    await stopping.value
    XCTAssertLessThan(stopped.duration(to: .now), .seconds(1))
    XCTAssertEqual(fixture.engines[0].stopCount, 1)
  }

  func testReleaseStopDoesNotWaitForAnEngineThatStopped() async throws {
    let fixture = AudioPreparationFixture()
    let service = fixture.service()
    _ = try await service.start()
    fixture.engines[0].stop()
    let started = ContinuousClock.now
    await service.beginStop(atHostTime: host(mach_absolute_time(), plus: 500)).wait()
    XCTAssertLessThan(started.duration(to: .now), .seconds(1))
  }

  func testReleaseAfterItsBlockWasDeliveredEndsCaptureAtOnce() async throws {
    let fixture = AudioPreparationFixture()
    let service = fixture.service()
    let delivered = LockedBytes()
    service.onAudio = { delivered.append($0) }
    _ = try await service.start()
    let start = mach_absolute_time()
    fixture.engines[0].emit(try makeBuffer(sampleRate: 48_000, frameCount: block), hostTime: start)
    XCTAssertFalse(service.isWaitingForReleaseBlock)
    // The block holding the release went through before the release reached the service.
    let stopping = ContinuousClock.now
    await service.beginStop(atHostTime: host(start, plus: 60)).wait()
    XCTAssertLessThan(stopping.duration(to: .now), .seconds(1), "No block is left to wait for")
    XCTAssertEqual(fixture.engines[0].stopCount, 1)
    XCTAssertEqual(samples(delivered), 1_600, accuracy: 32)
  }

  func testInputChangeDuringAReleaseWaitOpensNoOtherMicrophone() async throws {
    let fixture = AudioPreparationFixture()
    let service = fixture.service()
    _ = try await service.start()
    let stopping = try await beginReleaseStop(service, at: host(mach_absolute_time(), plus: 500))
    fixture.route = AudioInputRoute(deviceID: AudioDeviceID(2), sampleRate: 48_000, channels: 1)
    // A running engine can still deliver the block holding the release.
    NotificationCenter.default.post(
      name: .AVAudioEngineConfigurationChange, object: fixture.engines[0].notificationObject)
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertTrue(service.isWaitingForReleaseBlock)
    // A stopped one cannot, so capture ends without moving to the new input.
    let waited = ContinuousClock.now
    fixture.engines[0].stop()
    NotificationCenter.default.post(
      name: .AVAudioEngineConfigurationChange, object: fixture.engines[0].notificationObject)
    await stopping.value
    XCTAssertLessThan(waited.duration(to: .now), .seconds(1))
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertEqual(fixture.engines.count, 1)
  }

  func testReleaseCutArithmetic() {
    let start = mach_absolute_time()
    func cut(_ milliseconds: Double, start blockStart: UInt64? = start) -> (AVAudioFrameCount, Bool) {
      let result = CaptureRelease.cut(
        release: host(start, plus: milliseconds), blockStart: blockStart, frames: block,
        sampleRate: 48_000)
      return (result.keep, result.reachesRelease)
    }
    let half = cut(50)
    XCTAssertEqual(Double(half.0), 2_400, accuracy: 2)
    XCTAssertTrue(half.1)
    let before = cut(150)
    XCTAssertEqual(before.0, block)
    XCTAssertFalse(before.1)
    let after = cut(-10)
    XCTAssertEqual(after.0, 0)
    XCTAssertTrue(after.1)
    let unknown = cut(50, start: nil)
    XCTAssertEqual(unknown.0, block)
    XCTAssertTrue(unknown.1)
  }

  func testPrefixCopiesTheFirstFrames() throws {
    let buffer = try makeBuffer(sampleRate: 48_000, frameCount: 480)
    let prefix = try XCTUnwrap(buffer.prefix(100))
    XCTAssertEqual(prefix.frameLength, 100)
    XCTAssertEqual(prefix.format, buffer.format)
    let source = try XCTUnwrap(buffer.floatChannelData?[0])
    let copied = try XCTUnwrap(prefix.floatChannelData?[0])
    for frame in 0..<100 { XCTAssertEqual(copied[frame], source[frame]) }
  }

  func testConverterMixesAllInputChannels() throws {
    let converter = try XCTUnwrap(PCM16AudioConverter())
    // Speech only on the second input, as on a two-channel interface.
    let format = try XCTUnwrap(
      AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false))
    let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800))
    buffer.frameLength = 4_800
    let channels = try XCTUnwrap(buffer.floatChannelData)
    for frame in 0..<4_800 {
      channels[0][frame] = 0
      channels[1][frame] = 0.5 * sin(2 * Float.pi * 440 * Float(frame) / 48_000)
    }
    let data = try XCTUnwrap(converter.convert(buffer))
    XCTAssertGreaterThan(rms(data), 1_000)
  }

  func testHighPassRemovesRumbleAndKeepsSpeechBand() throws {
    func level(frequency: Float) throws -> Float {
      let converter = try XCTUnwrap(PCM16AudioConverter())
      var total: [Int16] = []
      for block in 0..<5 {
        let buffer = try makeBuffer(
          sampleRate: 48_000, frameCount: 4_800, frequency: frequency, offset: block * 4_800)
        let data = try XCTUnwrap(converter.convert(buffer))
        total += data.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
      }
      // Skip the filter's settling time.
      return rms(Data(total.dropFirst(4_000).withUnsafeBufferPointer { Data(buffer: $0) }))
    }
    let rumble = try level(frequency: 20)
    let speech = try level(frequency: 1_000)
    XCTAssertLessThan(rumble, speech * 0.1)
    let unfilteredLevel: Float = 0.5 * 32_767 / Float(2).squareRoot()
    XCTAssertGreaterThan(speech, 0.9 * unfilteredLevel)
  }

  private func rms(_ data: Data) -> Float {
    let samples = data.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
    guard !samples.isEmpty else { return 0 }
    let sum = samples.reduce(Float(0)) { $0 + Float($1) * Float($1) }
    return (sum / Float(samples.count)).squareRoot()
  }

  private func waitUntil(_ condition: () -> Bool) async throws {
    // Generous for a loaded machine; a passing condition returns as soon as it holds.
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    while !condition(), ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(5))
    }
    XCTAssertTrue(condition())
  }

  private func makeBuffer(
    sampleRate: Double, frameCount: AVAudioFrameCount, frequency: Float, offset: Int
  ) throws -> AVAudioPCMBuffer {
    let format = try XCTUnwrap(
      AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1,
        interleaved: false))
    let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
    buffer.frameLength = frameCount
    let samples = try XCTUnwrap(buffer.floatChannelData?[0])
    for frame in 0..<Int(frameCount) {
      let phase = 2 * Float.pi * frequency * Float(frame + offset) / Float(sampleRate)
      samples[frame] = 0.5 * sin(phase)
    }
    return buffer
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
  private var inputRoute: AudioInputRoute? = AudioInputRoute(
    deviceID: 1, sampleRate: 48_000, channels: 1)
  private var created: [FakeCaptureAudioEngine] = []
  private let factory: @Sendable (Int) -> FakeCaptureAudioEngine

  init(
    factory: @escaping @Sendable (Int) -> FakeCaptureAudioEngine = { _ in FakeCaptureAudioEngine() }
  ) {
    self.factory = factory
  }

  var route: AudioInputRoute {
    get { lock.withLock { inputRoute! } }
    set { lock.withLock { inputRoute = newValue } }
  }
  /// Nil models an input whose route can't be read.
  var optionalRoute: AudioInputRoute? {
    get { lock.withLock { inputRoute } }
    set { lock.withLock { inputRoute = newValue } }
  }
  var engines: [FakeCaptureAudioEngine] { lock.withLock { created } }

  func service(
    restartDebounce: DispatchTimeInterval = .milliseconds(10),
    releaseBlockTimeout: DispatchTimeInterval = .seconds(5)
  ) -> AudioCaptureService {
    AudioCaptureService(
      makeEngine: { _ in
        self.lock.withLock {
          let engine = self.factory(self.created.count)
          self.created.append(engine)
          return engine
        }
      }, currentRoute: { self.optionalRoute }, restartDebounce: restartDebounce,
      releaseBlockTimeout: releaseBlockTimeout)
  }
}

private final class FakeCaptureAudioEngine: CaptureAudioEngine, @unchecked Sendable {
  private let lock = NSLock()
  private let object = NSObject()
  private let prepareFails: Bool
  private let startFails: Bool
  private var bufferHandler: (@Sendable (AVAudioPCMBuffer, UInt64?) -> Void)?
  private let prepareEntered: XCTestExpectation?
  private let prepareGate: DispatchSemaphore?
  private let startEntered: XCTestExpectation?
  private let startGate: DispatchSemaphore?
  private var preparations = 0
  private var starts = 0
  private var stops = 0

  init(
    prepareFails: Bool = false, startFails: Bool = false, prepareEntered: XCTestExpectation? = nil,
    prepareGate: DispatchSemaphore? = nil, startEntered: XCTestExpectation? = nil,
    startGate: DispatchSemaphore? = nil
  ) {
    self.prepareFails = prepareFails
    self.startFails = startFails
    self.prepareEntered = prepareEntered
    self.prepareGate = prepareGate
    self.startEntered = startEntered
    self.startGate = startGate
  }

  var notificationObject: AnyObject { object }
  var isRunning: Bool { lock.withLock { starts > stops } }
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
    onBuffer: @escaping @Sendable (AVAudioPCMBuffer, UInt64?) -> Void
  ) throws -> CaptureEngineStartSteps {
    startEntered?.fulfill()
    if let startGate { XCTAssertEqual(startGate.wait(timeout: .now() + 3), .success) }
    try checkCancellation()
    if startFails { throw AppError.microphoneUnavailable }
    lock.withLock {
      starts += 1
      bufferHandler = onBuffer
    }
    return Self.steps
  }

  static let steps = CaptureEngineStartSteps(
    tapInstall: .milliseconds(4), prepare: .milliseconds(5), start: .milliseconds(6))

  /// `hostTime` is when the block's first frame was captured; nil models an unknown time.
  func emit(_ buffer: AVAudioPCMBuffer, hostTime: UInt64? = nil) {
    lock.withLock { bufferHandler }?(buffer, hostTime)
  }

  func stop() { lock.withLock { stops += 1 } }
}

private final class LockedFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var flag = false
  var value: Bool { lock.withLock { flag } }
  func set() { lock.withLock { flag = true } }
}

private final class LockedBytes: @unchecked Sendable {
  private let lock = NSLock()
  private var data = Data()
  private var appended = 0
  var count: Int { lock.withLock { data.count } }
  /// How many deliveries arrived.
  var chunks: Int { lock.withLock { appended } }
  func append(_ chunk: Data) {
    lock.withLock {
      data.append(chunk)
      appended += 1
    }
  }
}

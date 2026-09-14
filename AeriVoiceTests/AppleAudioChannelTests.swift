import XCTest
@testable import AeriVoice

@MainActor
final class AppleAudioChannelTests: XCTestCase {
  func testDelayedConsumerReceivesEntireStartupBurstInOrder() async throws {
    let channel = AppleAudioChannel<Int>(capacity: 16)
    let started = AppleAudioChannel<Bool>(capacity: 1)
    var sentCount = 0
    let producer = Task { @MainActor in
      for frame in 0..<150 {
        if frame == 16 { try await started.send(true) }
        try await channel.send(frame)
        sentCount += 1
      }
      channel.finish()
    }
    var signal = started.makeAsyncIterator()
    _ = try await signal.next()
    try await Task.sleep(for: .milliseconds(25))
    XCTAssertEqual(sentCount, 16, "A full queue must suspend the startup burst")
    var received: [Int] = []
    for try await frame in channel { received.append(frame) }
    try await producer.value
    XCTAssertEqual(received, Array(0..<150))
  }

  func testFinishDrainsAcceptedBuffersBeforeEndOfInput() async throws {
    let channel = AppleAudioChannel<Int>(capacity: 3)
    try await channel.send(1)
    try await channel.send(2)
    try await channel.send(3)
    channel.finish()
    var received: [Int] = []
    for try await value in channel { received.append(value) }
    XCTAssertEqual(received, [1, 2, 3])
    do {
      try await channel.send(4)
      XCTFail("Closed input must reject new frames")
    } catch { XCTAssertTrue(error is CancellationError) }
  }

  func testCancelUnblocksPendingProducerAndDiscardsBuffers() async throws {
    let channel = AppleAudioChannel<Int>(capacity: 1)
    try await channel.send(1)
    let started = AppleAudioChannel<Bool>(capacity: 1)
    let producer = Task {
      try await started.send(true)
      do { try await channel.send(2); return false }
      catch { return error is CancellationError }
    }
    var signal = started.makeAsyncIterator()
    _ = try await signal.next()
    await Task.yield()
    channel.cancel()
    let cancelled = try await producer.value
    XCTAssertTrue(cancelled)
    var iterator = channel.makeAsyncIterator()
    do { _ = try await iterator.next(); XCTFail("Cancelled input must discard buffered audio") }
    catch { XCTAssertTrue(error is CancellationError) }
  }

  func testTaskCancellationUnblocksPendingConsumer() async throws {
    let channel = AppleAudioChannel<Int>()
    let started = AppleAudioChannel<Bool>(capacity: 1)
    let consumer = Task {
      try await started.send(true)
      var iterator = channel.makeAsyncIterator()
      do { _ = try await iterator.next(); return false }
      catch { return error is CancellationError }
    }
    var signal = started.makeAsyncIterator()
    _ = try await signal.next()
    await Task.yield()
    consumer.cancel()
    let cancelled = try await consumer.value
    XCTAssertTrue(cancelled)
  }

  func testCancelledSessionCannotFeedFreshChannel() async throws {
    let old = AppleAudioChannel<Int>(capacity: 1)
    try await old.send(1)
    old.cancel()
    let fresh = AppleAudioChannel<Int>(capacity: 1)
    try await fresh.send(9)
    fresh.finish()
    do { try await old.send(2); XCTFail("The old session must stay closed") }
    catch { XCTAssertTrue(error is CancellationError) }
    var received: [Int] = []
    for try await value in fresh { received.append(value) }
    XCTAssertEqual(received, [9])
  }
}

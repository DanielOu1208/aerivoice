import Foundation

/// A single-consumer audio queue. Full buffers suspend the producer instead of
/// dropping startup audio. All state and continuations are protected by the lock.
final class AppleAudioChannel<Element: Sendable>: AsyncSequence, @unchecked Sendable {
  struct AsyncIterator: AsyncIteratorProtocol {
    let channel: AppleAudioChannel
    mutating func next() async throws -> Element? { try await channel.receive() }
  }

  private enum State { case open, finished, cancelled }
  private let lock = NSLock()
  private let capacity: Int
  private var state = State.open
  private var buffer: [Element] = []
  private var producers: [(Element, CheckedContinuation<Void, Error>)] = []
  private var consumer: CheckedContinuation<Element?, Error>?

  init(capacity: Int = 16) {
    precondition(capacity > 0)
    self.capacity = capacity
  }

  func makeAsyncIterator() -> AsyncIterator { AsyncIterator(channel: self) }

  func send(_ element: Element) async throws {
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        lock.withLock {
          guard state == .open, !Task.isCancelled else {
            continuation.resume(throwing: CancellationError())
            return
          }
          if let consumer {
            self.consumer = nil
            consumer.resume(returning: element)
            continuation.resume()
          } else if buffer.count < capacity {
            buffer.append(element)
            continuation.resume()
          } else {
            producers.append((element, continuation))
          }
        }
      }
    } onCancel: { self.cancel() }
  }

  private func receive() async throws -> Element? {
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        lock.withLock {
          guard state != .cancelled, !Task.isCancelled else {
            continuation.resume(throwing: CancellationError())
            return
          }
          if !buffer.isEmpty {
            let element = buffer.removeFirst()
            if !producers.isEmpty {
              let (next, producer) = producers.removeFirst()
              buffer.append(next)
              producer.resume()
            }
            continuation.resume(returning: element)
          } else if state == .finished {
            continuation.resume(returning: nil)
          } else {
            precondition(consumer == nil, "Apple audio supports one consumer")
            consumer = continuation
          }
        }
      }
    } onCancel: { self.cancel() }
  }

  /// End input after all awaited sends. Already accepted buffers still drain.
  func finish() {
    lock.withLock {
      guard state == .open else { return }
      state = .finished
      for (_, producer) in producers { producer.resume(throwing: CancellationError()) }
      producers.removeAll()
      consumer?.resume(returning: nil)
      consumer = nil
    }
  }

  /// Cancellation discards queued audio and releases every suspended operation.
  func cancel() {
    lock.withLock {
      state = .cancelled
      buffer.removeAll()
      for (_, producer) in producers { producer.resume(throwing: CancellationError()) }
      producers.removeAll()
      consumer?.resume(throwing: CancellationError())
      consumer = nil
    }
  }
}

import AppKit

/// A data request is evidence of a reader, not proof that the target pasted.
/// AppKit may call the provider off the main thread. Only the small receipt
/// state is locked; providing the immutable text never waits for MainActor.
final class ClipboardReadReceipt: NSObject, NSPasteboardItemDataProvider, @unchecked Sendable {
  private let text: String
  private let lock = NSLock()
  private var dispatchStarted = false
  private var readBeforeDispatch = false
  private var stopped = false
  private var receipt: ContinuousClock.Instant?

  init(text: String) { self.text = text }

  func beginDispatch() { lock.withLock { dispatchStarted = true } }
  func stop() { lock.withLock { stopped = true } }

  var lastEligibleRead: ContinuousClock.Instant? {
    lock.withLock { readBeforeDispatch || stopped ? nil : receipt }
  }

  func pasteboard(
    _ pasteboard: NSPasteboard?, item: NSPasteboardItem,
    provideDataForType type: NSPasteboard.PasteboardType
  ) {
    guard type == .string else { return }
    let requestedAt = ContinuousClock.now
    let beganAfterDispatch = lock.withLock { dispatchStarted }
    guard item.setString(text, forType: type) else { return }
    lock.withLock {
      if !stopped {
        if beganAfterDispatch { receipt = requestedAt }
        else { readBeforeDispatch = true }
      }
    }
    // Once fulfilled, pasteboard data may be cached: later reads need not call
    // this provider again. Never treat a pre-dispatch read as an eligible one.
  }
}

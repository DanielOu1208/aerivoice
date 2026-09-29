import AppKit

/// Values are retained only for the short verification window, never logged.
struct TextEditState: Equatable, Sendable {
  static let maximumUTF16Length = 1_000_000
  let text: String
  let selection: NSRange

  var isValid: Bool {
    let value = text as NSString
    guard value.length <= Self.maximumUTF16Length,
      selection.location >= 0, selection.length >= 0,
      selection.location <= value.length,
      selection.length <= value.length - selection.location
    else { return false }
    return Self.isScalarBoundary(selection.location, in: value)
      && Self.isScalarBoundary(selection.location + selection.length, in: value)
  }

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.selection == rhs.selection && lhs.text.utf16.elementsEqual(rhs.text.utf16)
  }

  func replacingSelection(with replacement: String) -> TextEditState? {
    let original = text as NSString
    let replacementLength = replacement.utf16.count
    guard isValid,
      replacementLength <= Self.maximumUTF16Length - (original.length - selection.length)
    else { return nil }
    let expected = original.replacingCharacters(in: selection, with: replacement)
    // Swift String equality folds canonically equivalent Unicode sequences; this
    // check must compare actual UTF-16 units, as do the accessibility offsets.
    guard !expected.utf16.elementsEqual(text.utf16) else { return nil }
    return Self(text: expected, selection: NSRange(
      location: selection.location + replacementLength, length: 0))
  }

  private static func isScalarBoundary(_ offset: Int, in value: NSString) -> Bool {
    guard offset > 0, offset < value.length else { return true }
    return !(0xD800...0xDBFF).contains(value.character(at: offset - 1))
      || !(0xDC00...0xDFFF).contains(value.character(at: offset))
  }

}

struct TextVerificationSource: Sendable {
  let prepare: @MainActor @Sendable () -> TextEditState?
  let read: @Sendable () async -> TextEditState?
  let isCurrent: @MainActor @Sendable () -> Bool
}

enum ClipboardRestorationOutcome: String, Codable, Sendable {
  case restored, unverified, backupUnavailable, superseded, cancelled, failed, disabled
  case restoredAfterRead, noEligibleRead, restoredAfterDelay
}

/// Owns only optional work after Paste. Clipboard mutations remain on MainActor.
@MainActor
final class ClipboardRestoration {
  typealias Report = @MainActor (ClipboardRestorationOutcome) -> Void
  typealias SnapshotReader = @Sendable (String, Int) -> ClipboardSnapshot?

  struct Timing {
    var poll: Duration = .milliseconds(50)
    var grace: Duration = .milliseconds(100)
    var timeout: Duration = .seconds(2)
    var readGrace: Duration = .milliseconds(500)
    /// Timers can wake late under load; the drain must not cancel a restoration that is due.
    var drainMargin: Duration = .milliseconds(500)
  }

  // A new service/capture on the same board also invalidates older generations.
  private static var owners: [NSPasteboard.Name: UUID] = [:]
  private static var readingBoards: Set<NSPasteboard.Name> = []
  private let board: NSPasteboard
  private let readSnapshot: SnapshotReader
  private let timing: Timing
  private var generation: UUID?
  private var acceptingSnapshot = false
  private(set) var preparedSnapshot: ClipboardSnapshot?
  private var task: Task<Void, Never>?
  private var report: Report?
  private var terminationWaiters: [CheckedContinuation<Void, Never>] = []
  private struct PendingPaste {
    let snapshot: ClipboardSnapshot
    let receipt: ClipboardReadReceipt?
    let markerType: NSPasteboard.PasteboardType
    let marker: String
    let changeCount: Int
    let text: String
  }
  private var pendingPaste: PendingPaste?
  private var pendingDelay: Duration?
  private var delayedDeadline: ContinuousClock.Instant?
  private struct PreviousPaste {
    let paste: PendingPaste
    let deadline: ContinuousClock.Instant
  }
  private var previousPaste: PreviousPaste?
  var hasDelayedPaste: Bool { delayedDeadline != nil }

  init(
    board: NSPasteboard, timing: Timing = Timing(),
    readSnapshot: @escaping SnapshotReader = { name, count in
      ClipboardSnapshot.capture(from: NSPasteboard(name: .init(name)), expectedChangeCount: count)
    }
  ) {
    self.board = board
    self.timing = timing
    self.readSnapshot = readSnapshot
  }

  func invalidate() {
    task?.cancel()
    task = nil
    if let pendingPaste {
      pendingPaste.receipt?.stop()
      if pendingPaste.receipt != nil, owns(pendingPaste) {
        // Materialize before releasing the provider, without clearing the
        // board or overwriting anything another owner has copied.
        board.setString(pendingPaste.text, forType: .string)
      }
    }
    pendingPaste = nil
    pendingDelay = nil
    delayedDeadline = nil
    previousPaste = nil
    preparedSnapshot = nil
    acceptingSnapshot = false
    if let generation, Self.owners[board.name] == generation {
      Self.owners.removeValue(forKey: board.name)
    }
    generation = nil
    let completion = report
    report = nil
    completion?(.cancelled)
    let waiters = terminationWaiters
    terminationWaiters.removeAll()
    for waiter in waiters { waiter.resume() }
  }

  /// Give an already-dispatched paste its normal verification window before an
  /// update exits the process. A stalled destination must not block termination.
  func finishPendingRestoration() async {
    guard task != nil, let id = generation else { return }
    let drainTimeout = pendingDelay ?? (timing.timeout + (pendingPaste?.receipt == nil ? .zero : timing.readGrace))
    let deadline = Task { [weak self, timing] in
      do { try await Task.sleep(for: drainTimeout + timing.drainMargin) } catch { return }
      self?.invalidate(ifCurrent: id)
    }
    await withCheckedContinuation { terminationWaiters.append($0) }
    deadline.cancel()
  }

  func invalidate(ifCurrent id: UUID) {
    if generation == id { invalidate() }
  }

  /// If a later dictation ends before touching the clipboard, resume the earlier
  /// successful paste's timer using its original deadline and ownership marker.
  func abandonCapture(ifCurrent id: UUID? = nil) {
    if let id, !isCurrent(id) { return }
    guard let previous = previousPaste, owns(previous.paste) else {
      invalidate()
      return
    }
    invalidate()
    let resumedID = activate()
    pendingPaste = previous.paste
    let remaining = ContinuousClock.now.duration(to: previous.deadline)
    let seconds = Double(remaining.components.seconds)
      + Double(remaining.components.attoseconds) / 1e18
    restoreAfterDelay(id: resumedID, delay: max(0.001, seconds), report: { _ in })
  }

  /// Carry the original clipboard across overlapping dictations.
  /// Settle the old promise before the caller records the new change count.
  func takePendingBackup() -> ClipboardSnapshot? {
    let pending = pendingPaste.flatMap { owns($0) ? $0 : nil }
    let previous = pending.flatMap { paste in
      delayedDeadline.map { PreviousPaste(paste: paste, deadline: $0) }
    }
    invalidate()
    previousPaste = previous
    return pending?.snapshot
  }

  func beginCapture(changeCount: Int, enabled: Bool, backup: ClipboardSnapshot? = nil) -> UUID? {
    let previous = previousPaste
    invalidate()
    guard enabled else { return nil }
    previousPaste = previous
    let id = activate()
    if let backup {
      preparedSnapshot = ClipboardSnapshot(changeCount: changeCount, items: backup.items)
      return id
    }
    guard Self.readingBoards.insert(board.name).inserted else { return id }
    acceptingSnapshot = true
    let name = board.name.rawValue
    let reader = readSnapshot
    // One materialization per board, even when an external data provider blocks.
    // Cancellation never releases this slot early or queues more provider work.
    // The paste may wait on this backup, so it must not be starved under CPU load.
    Task.detached(priority: .userInitiated) { [weak self] in
      let snapshot = reader(name, changeCount)
      await MainActor.run {
        Self.readingBoards.remove(.init(name))
        guard let self, self.isCurrent(id), self.acceptingSnapshot else { return }
        self.preparedSnapshot = snapshot
        self.acceptingSnapshot = false
      }
    }
    return id
  }

  func beginInsertion(captureID: UUID?) -> UUID {
    if let captureID { return captureID }
    invalidate()
    return activate()
  }

  func takeSnapshot(for id: UUID) -> ClipboardSnapshot? {
    guard isCurrent(id) else { return nil }
    acceptingSnapshot = false
    defer { preparedSnapshot = nil }
    return preparedSnapshot
  }

  /// Wait only for the already-running bounded snapshot worker. The provider
  /// itself may block, so cancellation must never release its concurrency slot.
  func waitForSnapshot(for id: UUID, timeout: Duration = .milliseconds(100)) async {
    let expires = ContinuousClock.now.advanced(by: timeout)
    while isCurrent(id), acceptingSnapshot, !Task.isCancelled, ContinuousClock.now < expires {
      do { try await Task.sleep(for: .milliseconds(2)) } catch { return }
    }
  }

  func trackPaste(
    id: UUID, snapshot: ClipboardSnapshot, receipt: ClipboardReadReceipt?,
    markerType: NSPasteboard.PasteboardType, marker: String, changeCount: Int, text: String
  ) {
    guard isCurrent(id) else { return }
    previousPaste = nil
    pendingPaste = PendingPaste(
      snapshot: snapshot, receipt: receipt, markerType: markerType, marker: marker,
      changeCount: changeCount, text: text)
  }

  /// A compatibility fallback, not proof that the destination consumed the text.
  /// A focus change does not revoke our clipboard ownership; a new copy does.
  func restoreAfterDelay(id: UUID, delay: TimeInterval, report: @escaping Report) {
    guard isCurrent(id), let pending = pendingPaste, delay.isFinite, delay > 0 else {
      finishWithoutRestoring(.unverified, id: id, report: report)
      return
    }
    let duration = Duration.seconds(min(delay, 30))
    pendingDelay = duration
    delayedDeadline = ContinuousClock.now.advanced(by: duration)
    self.report = report
    task = Task { [weak self] in
      do { try await Task.sleep(for: duration) } catch { return }
      guard let self, !Task.isCancelled, self.isCurrent(id) else { return }
      guard self.owns(pending) else {
        self.complete(id: id, outcome: .superseded)
        return
      }
      let outcome: ClipboardRestorationOutcome
      switch pending.snapshot.restore(
        to: self.board, markerType: pending.markerType, marker: pending.marker,
        ownedChangeCount: pending.changeCount, dictation: pending.text)
      {
      case .restored: outcome = .restoredAfterDelay
      case .superseded: outcome = .superseded
      case .failed: outcome = .failed
      }
      self.complete(id: id, outcome: outcome)
    }
  }

  func verifyRead(
    id: UUID, source: TextVerificationSource?, report: @escaping Report
  ) {
    guard isCurrent(id), let pending = pendingPaste, let receipt = pending.receipt else {
      report(.superseded)
      return
    }
    self.report = report
    let expires = ContinuousClock.now.advanced(by: timing.timeout)
    let graceExpires = expires.advanced(by: timing.readGrace)
    task = Task { [weak self] in
      var outcome: ClipboardRestorationOutcome = .noEligibleRead
      while !Task.isCancelled, ContinuousClock.now < graceExpires {
        guard let self else { return }
        guard self.isCurrent(id), self.owns(pending) else { outcome = .superseded; break }
        let read = receipt.lastEligibleRead.flatMap { $0 <= expires ? $0 : nil }
        if let read, read.duration(to: .now) >= self.timing.readGrace {
          // If a target identity is available it remains an additional guard;
          // unlike exact text readback, it does not need AXValue support.
          guard source?.isCurrent() != false, !Task.isCancelled,
            ContinuousClock.now < graceExpires,
            self.isCurrent(id), self.owns(pending) else { outcome = .unverified; break }
          switch pending.snapshot.restore(
            to: self.board, markerType: pending.markerType, marker: pending.marker,
            ownedChangeCount: pending.changeCount, dictation: pending.text)
          {
          case .restored: outcome = .restoredAfterRead
          case .superseded: outcome = .superseded
          case .failed: outcome = .failed
          }
          break
        }
        if ContinuousClock.now >= expires, read == nil { break }
        do { try await Task.sleep(for: self.timing.poll) } catch { break }
      }
      self?.complete(id: id, outcome: outcome)
    }
  }

  private func owns(_ pending: PendingPaste) -> Bool {
    ClipboardOwnership.isCurrent(
      currentMarker: board.string(forType: pending.markerType), expectedMarker: pending.marker,
      currentChangeCount: board.changeCount, expectedChangeCount: pending.changeCount)
  }

  func finishWithoutRestoring(_ outcome: ClipboardRestorationOutcome, id: UUID, report: Report) {
    if isCurrent(id) { invalidate() }
    report(outcome)
  }

  func verify(
    id: UUID, snapshot: ClipboardSnapshot, before: TextEditState, expected: TextEditState,
    source: TextVerificationSource, markerType: NSPasteboard.PasteboardType,
    marker: String, ownedChangeCount: Int, dictation: String, report: @escaping Report
  ) {
    guard isCurrent(id) else { report(.superseded); return }
    self.report = report
    let expires = ContinuousClock.now.advanced(by: timing.timeout)
    task = Task { [weak self] in
      var outcome: ClipboardRestorationOutcome = .unverified
      while !Task.isCancelled, ContinuousClock.now < expires {
        guard let self else { return }
        guard self.ownsClipboard(id, markerType, marker, ownedChangeCount) else {
          outcome = .superseded
          break
        }
        guard let state = await source.read() else { break }
        guard !Task.isCancelled, self.isCurrent(id), ContinuousClock.now < expires else { break }
        if state == expected {
          do { try await Task.sleep(for: self.timing.grace) } catch { break }
          guard ContinuousClock.now < expires,
            await source.read() == expected,
            !Task.isCancelled, ContinuousClock.now < expires,
            self.ownsClipboard(id, markerType, marker, ownedChangeCount), source.isCurrent()
          else { break }
          switch snapshot.restore(
            to: self.board, markerType: markerType, marker: marker,
            ownedChangeCount: ownedChangeCount, dictation: dictation)
          {
          case .restored: outcome = .restored
          case .superseded: outcome = .superseded
          case .failed: outcome = .failed
          }
          break
        }
        // A different edit is not evidence of this Paste; do not wait for it to undo.
        guard state == before else { break }
        do { try await Task.sleep(for: self.timing.poll) } catch { break }
      }
      self?.complete(id: id, outcome: outcome)
    }
  }

  private func activate() -> UUID {
    let id = UUID()
    generation = id
    Self.owners[board.name] = id
    return id
  }

  private func isCurrent(_ id: UUID) -> Bool {
    generation == id && Self.owners[board.name] == id
  }

  private func ownsClipboard(
    _ id: UUID, _ markerType: NSPasteboard.PasteboardType, _ marker: String, _ count: Int
  ) -> Bool {
    isCurrent(id) && ClipboardOwnership.isCurrent(
      currentMarker: board.string(forType: markerType), expectedMarker: marker,
      currentChangeCount: board.changeCount, expectedChangeCount: count)
  }

  private func complete(id: UUID, outcome: ClipboardRestorationOutcome) {
    guard generation == id else { return }
    let completion = report
    report = nil
    invalidate()
    completion?(outcome)
  }
}

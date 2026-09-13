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
    preparedSnapshot = nil
    acceptingSnapshot = false
    if let generation, Self.owners[board.name] == generation {
      Self.owners.removeValue(forKey: board.name)
    }
    generation = nil
    let completion = report
    report = nil
    completion?(.cancelled)
  }

  func invalidate(ifCurrent id: UUID) {
    if generation == id { invalidate() }
  }

  func beginCapture(changeCount: Int, enabled: Bool) -> UUID? {
    invalidate()
    guard enabled else { return nil }
    let id = activate()
    guard Self.readingBoards.insert(board.name).inserted else { return id }
    acceptingSnapshot = true
    let name = board.name.rawValue
    let reader = readSnapshot
    // One materialization per board, even when an external data provider blocks.
    // Cancellation never releases this slot early or queues more provider work.
    Task.detached(priority: .utility) { [weak self] in
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

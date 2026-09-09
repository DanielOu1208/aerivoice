import AppKit
import XCTest

@testable import AeriVoice

@MainActor
final class ClipboardRestorationTests: XCTestCase {
  func testReplacementUsesUTF16AndRejectsNoOpInvalidAndOversizedStates() {
    let original = "👋 old suffix"
    let range = (original as NSString).range(of: "old")
    let state = TextEditState(text: original, selection: range)
    let replacement = "café e\u{301} 中文 👨‍👩‍👧‍👦\nsecond line"
    XCTAssertEqual(state.replacingSelection(with: replacement), TextEditState(
      text: "👋 " + replacement + " suffix",
      selection: NSRange(location: range.location + replacement.utf16.count, length: 0)))
    XCTAssertNil(state.replacingSelection(with: "old"))
    XCTAssertNotEqual(
      TextEditState(text: "é", selection: NSRange(location: 0, length: 0)),
      TextEditState(text: "e\u{301}", selection: NSRange(location: 0, length: 0)))
    XCTAssertNil(TextEditState(text: "👋", selection: NSRange(location: 1, length: 0))
      .replacingSelection(with: "x"))
    XCTAssertNil(TextEditState(text: "x", selection: NSRange(location: Int.max, length: 1))
      .replacingSelection(with: "x"))
    XCTAssertNil(TextEditState(text: "x", selection: NSRange(location: 0, length: Int.max))
      .replacingSelection(with: "x"))
    XCTAssertNil(state.replacingSelection(with: String(repeating: "a", count: 1_000_001)))
  }

  func testExactPasteRestoresBackupAfterReturningPasteSent() async throws {
    let fixture = Fixture()
    defer { fixture.remove() }
    let target = try await fixture.capture()
    let result = await fixture.service.insert(fixture.dictation, into: target)
    XCTAssertEqual(result, .pasteSent)
    XCTAssertEqual(fixture.board.string(forType: .string), fixture.dictation)
    try await waitUntil { fixture.outcomes == [.restored] }
    XCTAssertEqual(fixture.board.string(forType: .string), "previous clipboard")
    XCTAssertEqual(fixture.editor.dispatches, 1)
  }

  func testIgnoredPasteTimesOutWithoutRestoring() async throws {
    let fixture = Fixture()
    defer { fixture.remove() }
    fixture.editor.acceptsPaste = false
    let target = try await fixture.capture()
    _ = await fixture.service.insert(fixture.dictation, into: target)
    try await waitUntil { !fixture.outcomes.isEmpty }
    XCTAssertEqual(fixture.outcomes, [.unverified])
    XCTAssertEqual(fixture.board.string(forType: .string), fixture.dictation)
  }

  func testDelayedPasteWithinVerificationWindowRestores() async throws {
    let fixture = Fixture()
    defer { fixture.remove() }
    fixture.editor.acceptsPaste = false
    fixture.editor.onRead = { [weak fixture] count in
      guard count == 3, let fixture else { return }
      fixture.editor.state = fixture.editor.expected
    }
    let target = try await fixture.capture()
    _ = await fixture.service.insert(fixture.dictation, into: target)
    try await waitUntil { fixture.outcomes == [.restored] }
    XCTAssertEqual(fixture.board.string(forType: .string), "previous clipboard")
  }

  func testUndoOrOtherEditDuringGracePreventsRestore() async throws {
    for undo in [true, false] {
      let fixture = Fixture()
      defer { fixture.remove() }
      fixture.editor.onRead = { [weak fixture] count in
        guard count == 2, let fixture else { return }
        fixture.editor.state = undo ? fixture.editor.before
          : TextEditState(text: "unrelated edit", selection: NSRange(location: 14, length: 0))
      }
      let target = try await fixture.capture()
      _ = await fixture.service.insert(fixture.dictation, into: target)
      try await waitUntil { !fixture.outcomes.isEmpty }
      XCTAssertEqual(fixture.outcomes, [.unverified])
      XCTAssertEqual(fixture.board.string(forType: .string), fixture.dictation)
    }
  }

  func testNewCopyIncludingIdenticalDictationIsPreservedDuringGrace() async throws {
    for copy in ["user copy", "café 中文 👋\nnext"] {
      let fixture = Fixture()
      defer { fixture.remove() }
      fixture.editor.onRead = { [weak fixture] count in
        guard count == 2, let fixture else { return }
        fixture.board.clearContents()
        fixture.board.setString(copy, forType: .string)
      }
      let target = try await fixture.capture()
      _ = await fixture.service.insert(fixture.dictation, into: target)
      try await waitUntil { !fixture.outcomes.isEmpty }
      XCTAssertNotEqual(fixture.outcomes, [.restored])
      XCTAssertEqual(fixture.board.string(forType: .string), copy)
    }
  }

  func testFocusChangeOrMissingReadbackKeepsDictation() async throws {
    for loseFocus in [true, false] {
      let fixture = Fixture()
      defer { fixture.remove() }
      fixture.editor.onRead = { [weak fixture] count in
        guard count == 1, let fixture else { return }
        if loseFocus { fixture.editor.current = false }
        else { fixture.editor.readable = false }
      }
      let target = try await fixture.capture()
      _ = await fixture.service.insert(fixture.dictation, into: target)
      try await waitUntil { !fixture.outcomes.isEmpty }
      XCTAssertEqual(fixture.outcomes, [.unverified])
      XCTAssertEqual(fixture.board.string(forType: .string), fixture.dictation)
    }
  }

  func testFailedOptionalProbeRevalidatesTargetBeforeDispatch() async throws {
    let fixture = Fixture()
    defer { fixture.remove() }
    fixture.editor.onPrepare = { [weak fixture] in
      fixture?.editor.current = false
      fixture?.editor.readable = false
    }
    let target = try await fixture.capture()
    let result = await fixture.service.insert(fixture.dictation, into: target)
    XCTAssertEqual(result, .copied(.targetChanged))
    XCTAssertEqual(fixture.editor.dispatches, 0)
    XCTAssertEqual(fixture.board.string(forType: .string), fixture.dictation)
  }

  func testUnsupportedProbeAndDisabledSettingDoNotChangePasteBehavior() async throws {
    for enabled in [true, false] {
      let fixture = Fixture()
      defer { fixture.remove() }
      fixture.enabled = enabled
      fixture.editor.readable = false
      let target = try await fixture.capture(waitForBackup: enabled)
      let result = await fixture.service.insert(fixture.dictation, into: target)
      XCTAssertEqual(result, .pasteSent)
      XCTAssertEqual(fixture.editor.dispatches, 1)
      XCTAssertEqual(fixture.outcomes, [enabled ? .unverified : .disabled])
      XCTAssertEqual(fixture.board.string(forType: .string), fixture.dictation)
    }
  }

  func testSlowTargetSkipsOptionalProbeAndStillPastes() async throws {
    let fixture = Fixture()
    defer { fixture.remove() }
    var probes = 0
    fixture.editor.onPrepare = { probes += 1 }
    let original = try await fixture.capture()
    let target = TextInsertionTarget(
      clipboardChangeCount: original.clipboardChangeCount,
      restorationID: original.restorationID, verification: original.verification
    ) { commit in
      try? await Task.sleep(for: .milliseconds(570))
      return await original.perform(commit)
    }
    let result = await fixture.service.insert(fixture.dictation, into: target)
    XCTAssertEqual(result, .pasteSent)
    XCTAssertEqual(probes, 0)
    XCTAssertEqual(fixture.outcomes, [.unverified])
    XCTAssertEqual(fixture.board.string(forType: .string), fixture.dictation)
  }

  func testUnavailableBackupDoesNotPreventPasteOrStartVerification() async throws {
    let fixture = Fixture(reader: { _, _ in nil })
    defer { fixture.remove() }
    let target = try await fixture.capture(waitForBackup: false)
    let result = await fixture.service.insert(fixture.dictation, into: target)
    XCTAssertEqual(result, .pasteSent)
    XCTAssertEqual(fixture.outcomes, [.backupUnavailable])
    XCTAssertEqual(fixture.editor.readCount, 0)
    XCTAssertEqual(fixture.board.string(forType: .string), fixture.dictation)
  }

  func testInvalidationDuringGraceCancelsWithoutRestoring() async throws {
    let fixture = Fixture()
    defer { fixture.remove() }
    fixture.editor.onRead = { [weak fixture] count in
      if count == 1 { fixture?.service.invalidatePendingRestoration() }
    }
    let target = try await fixture.capture()
    _ = await fixture.service.insert(fixture.dictation, into: target)
    try await waitUntil { !fixture.outcomes.isEmpty }
    XCTAssertEqual(fixture.outcomes, [.cancelled])
    XCTAssertEqual(fixture.board.string(forType: .string), fixture.dictation)
  }

  func testNewCapturePreventsLateRegistrationFromOlderInsertion() async throws {
    let fixture = Fixture()
    defer { fixture.remove() }
    var target = try await fixture.capture()
    let perform = target.perform
    target = TextInsertionTarget(
      clipboardChangeCount: target.clipboardChangeCount,
      restorationID: target.restorationID, verification: target.verification
    ) { commit in
      let result = await perform(commit)
      // Re-enter after Paste but before the first insert call registers its verifier.
      let newerCapture = await fixture.service.captureTarget()
      _ = await newerCapture.value
      return result
    }
    let result = await fixture.service.insert(fixture.dictation, into: target)
    XCTAssertEqual(result, .pasteSent)
    XCTAssertEqual(fixture.outcomes, [.superseded])
    XCTAssertEqual(fixture.board.string(forType: .string), fixture.dictation)
  }

  func testAnotherServiceOnSameBoardInvalidatesPendingRestoration() async throws {
    let fixture = Fixture()
    defer { fixture.remove() }
    let second = TextInsertionService(pasteboard: fixture.board)
    fixture.editor.onRead = { [weak fixture] count in
      guard count == 1, let fixture else { return }
      Task { _ = await second.insert("next dictation", into: nil) }
      fixture.editor.acceptsPaste = false
    }
    let target = try await fixture.capture()
    _ = await fixture.service.insert(fixture.dictation, into: target)
    try await waitUntil { !fixture.outcomes.isEmpty }
    XCTAssertNotEqual(fixture.outcomes, [.restored])
    XCTAssertEqual(fixture.board.string(forType: .string), "next dictation")
    second.invalidatePendingRestoration()
  }

  func testBlockedProviderDoesNotDelayPasteOrQueueMoreBackups() async throws {
    let gate = BlockingSnapshotReader()
    let fixture = Fixture(reader: { name, count in gate.read(name, count) })
    defer { gate.release(); fixture.remove() }
    let target = try await fixture.capture(waitForBackup: false)
    try await waitUntil { gate.started }
    let result = await fixture.service.insert(fixture.dictation, into: target)
    XCTAssertEqual(result, .pasteSent)
    XCTAssertEqual(fixture.outcomes, [.backupUnavailable])
    _ = await fixture.service.captureTarget().value
    XCTAssertEqual(gate.reads, 1)
    fixture.service.invalidatePendingRestoration()
    gate.release()
    try await waitUntil { gate.finished }
    // Flush completion hops; the cancelled generation must not receive the late backup.
    for _ in 0..<10 { await Task.yield() }
    XCTAssertNil(fixture.restoration.preparedSnapshot)
  }

  private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while !condition(), ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(1))
    }
    XCTAssertTrue(condition(), "Timed out waiting for restoration")
  }
}

@MainActor
private final class Fixture {
  let board = NSPasteboard.withUniqueName()
  let dictation = "café 中文 👋\nnext"
  let editor: SyntheticEditor
  let restoration: ClipboardRestoration
  var enabled = true
  var outcomes: [ClipboardRestorationOutcome] = []
  lazy var service = TextInsertionService(
    pasteboard: board,
    capture: { [editor] in Task { editor.target() } },
    restoration: restoration,
    restoreEnabled: { [weak self] in self?.enabled == true },
    makeRestorationReport: { [weak self] in { [weak self] in self?.outcomes.append($0) } })

  init(reader: ClipboardRestoration.SnapshotReader? = nil) {
    board.setString("previous clipboard", forType: .string)
    editor = SyntheticEditor(dictation: dictation)
    let timing = ClipboardRestoration.Timing(
      poll: .milliseconds(1), grace: .milliseconds(5), timeout: .milliseconds(100))
    if let reader {
      restoration = ClipboardRestoration(board: board, timing: timing, readSnapshot: reader)
    } else {
      restoration = ClipboardRestoration(board: board, timing: timing)
    }
  }

  func capture(waitForBackup: Bool = true) async throws -> TextInsertionTarget {
    let target = await service.captureTarget().value
    if waitForBackup {
      let deadline = ContinuousClock.now.advanced(by: .seconds(2))
      while restoration.preparedSnapshot == nil, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(1))
      }
      XCTAssertNotNil(restoration.preparedSnapshot)
    }
    return try XCTUnwrap(target)
  }

  func remove() {
    service.invalidatePendingRestoration()
    board.releaseGlobally()
  }
}

@MainActor
private final class SyntheticEditor {
  let before = TextEditState(text: "prefix old suffix", selection: NSRange(location: 7, length: 3))
  let expected: TextEditState
  var state: TextEditState
  var current = true
  var readable = true
  var acceptsPaste = true
  var dispatches = 0
  var readCount = 0
  var onRead: ((Int) -> Void)?
  var onPrepare: (() -> Void)?

  init(dictation: String) {
    state = before
    expected = before.replacingSelection(with: dictation)!
  }

  func target() -> TextInsertionTarget {
    let source = TextVerificationSource(
      prepare: { [self] in
        onPrepare?()
        return readable ? state : nil
      },
      read: { [self] in await read() },
      isCurrent: { [self] in current })
    return TextInsertionTarget(verification: source) { [self] commit in
      await commit(
        { self.current ? nil : .targetChanged },
        {
          self.dispatches += 1
          if self.acceptsPaste { self.state = self.expected }
          return .pasteSent
        })
    }
  }

  private func read() -> TextEditState? {
    readCount += 1
    onRead?(readCount)
    return current && readable ? state : nil
  }
}

private final class BlockingSnapshotReader: @unchecked Sendable {
  private let condition = NSCondition()
  private var released = false
  private var count = 0
  private var done = false
  var reads: Int { condition.withLock { count } }
  var started: Bool { reads > 0 }
  var finished: Bool { condition.withLock { done } }

  func read(_ name: String, _ changeCount: Int) -> ClipboardSnapshot? {
    condition.lock()
    count += 1
    while !released { condition.wait() }
    done = true
    condition.unlock()
    return ClipboardSnapshot(changeCount: changeCount, items: [])
  }

  func release() {
    condition.lock()
    released = true
    condition.broadcast()
    condition.unlock()
  }
}

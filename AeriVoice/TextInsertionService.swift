import AppKit
import ApplicationServices
import Carbon

enum SecureTextStatus: Equatable {
  case secure
  case nonSecure
  case unknown

  static func resolve(subrole: String?, result: AXError) -> SecureTextStatus {
    switch result {
    case .success:
      guard let subrole else { return .unknown }
      return subrole == kAXSecureTextFieldSubrole as String ? .secure : .nonSecure
    case .attributeUnsupported, .noValue:
      return .nonSecure
    default:
      return .unknown
    }
  }
}

/// Paste eligibility is separate from whether accessibility can mutate text.
struct TextTargetTraits: Equatable {
  var roles: Set<String> = []
  var supportedAttributes: Set<String> = []
  var secureTextStatus: SecureTextStatus = .unknown
  var enabled: Bool?
  var editable: Bool?
}

enum TextTargetPolicy {
  static let textRoles: Set<String> = [
    kAXTextFieldRole as String, kAXTextAreaRole as String, kAXComboBoxRole as String,
  ]

  static func isTextTarget(_ traits: TextTargetTraits) -> Bool {
    guard traits.secureTextStatus == .nonSecure,
      traits.enabled != false, traits.editable != false
    else { return false }
    if !traits.roles.isDisjoint(with: textRoles) { return true }
    return traits.editable == true
      && traits.supportedAttributes.contains(kAXSelectedTextAttribute as String)
      && traits.supportedAttributes.contains(kAXSelectedTextRangeAttribute as String)
  }
}

enum FocusedElementRecovery {
  static func resolve<Element>(
    targetIsCurrent: () -> Bool,
    readFocus: () -> Element?,
    requestAccessibility: () -> Bool,
    isUsable: (Element) -> Bool = { _ in true },
    attempts: Int = 3,
    wait: () async throws -> Void = { try await Task.sleep(for: .milliseconds(50)) },
    isCancelled: () -> Bool = { Task.isCancelled }
  ) async -> Element? {
    guard !isCancelled(), targetIsCurrent() else { return nil }
    if let focus = readFocus(), isUsable(focus) {
      return !isCancelled() && targetIsCurrent() ? focus : nil
    }
    guard !isCancelled(), targetIsCurrent(), requestAccessibility() else { return nil }
    for _ in 0..<attempts {
      guard !isCancelled(), targetIsCurrent() else { return nil }
      do { try await wait() } catch { return nil }
      guard !isCancelled(), targetIsCurrent() else { return nil }
      if let focus = readFocus(), isUsable(focus) {
        return !isCancelled() && targetIsCurrent() ? focus : nil
      }
    }
    return nil
  }
}

/// Validation, clipboard write and dispatch run together without an actor hop.
typealias PasteCommit =
  @MainActor @Sendable (
    @MainActor @Sendable () -> PasteBlockReason?, @MainActor @Sendable () -> TargetInsertionOutcome
  ) -> TargetInsertionOutcome

struct TextInsertionTarget: Sendable {
  let id = UUID()
  var clipboardChangeCount: Int?
  let perform: @Sendable (@escaping PasteCommit) async -> TargetInsertionOutcome

  static func rejected(_ reason: PasteBlockReason) -> Self {
    Self { _ in .blocked(reason) }
  }
}

enum TargetInsertionOutcome: Equatable, Sendable {
  case pasteSent
  case blocked(PasteBlockReason)
}

@MainActor
final class TextInsertionService: TextInserting {
  private static let markerType = NSPasteboard.PasteboardType(
    "com.danielou.AeriVoice.clipboard-owner")
  private static var activeBoards: Set<NSPasteboard.Name> = []
  private let pasteboard: NSPasteboard
  private let capture: @MainActor () -> Task<TextInsertionTarget?, Never>

  init(
    pasteboard: NSPasteboard = .general,
    capture: @escaping @MainActor () -> Task<TextInsertionTarget?, Never> = captureSystemTarget
  ) {
    self.pasteboard = pasteboard
    self.capture = capture
  }

  func captureTarget() -> Task<TextInsertionTarget?, Never> {
    let changeCount = pasteboard.changeCount
    let acquisition = capture()
    return Task {
      await withTaskCancellationHandler {
        var target = await acquisition.value ?? .rejected(.targetUnavailable)
        target.clipboardChangeCount = changeCount
        return target
      } onCancel: {
        acquisition.cancel()
      }
    }
  }

  func insert(_ text: String, into target: TextInsertionTarget?) async -> InsertionResult {
    guard !Task.isCancelled else { return .cancelled }
    guard Self.activeBoards.insert(pasteboard.name).inserted else {
      return .failed("Another paste is still finishing—nothing copied.")
    }
    defer { Self.activeBoards.remove(pasteboard.name) }
    let initialChangeCount = target?.clipboardChangeCount ?? pasteboard.changeCount
    let marker = UUID().uuidString
    var ownedChangeCount: Int?
    var committedOutcome: TargetInsertionOutcome?

    // Preserve copies made after dictation stopped. Never restore on a timer:
    // a destination may read the clipboard well after its Paste event arrives.
    let copyIfUnchanged: @MainActor @Sendable () -> Bool = { [self] in
      guard !Task.isCancelled else { return false }
      if let ownedChangeCount {
        return ClipboardOwnership.isCurrent(
          currentMarker: pasteboard.string(forType: Self.markerType), expectedMarker: marker,
          currentChangeCount: pasteboard.changeCount, expectedChangeCount: ownedChangeCount)
      }
      guard pasteboard.changeCount == initialChangeCount else { return false }
      let item = NSPasteboardItem()
      guard item.setString(text, forType: .string),
        item.setString(marker, forType: Self.markerType)
      else { return false }
      pasteboard.clearContents()
      guard pasteboard.writeObjects([item]) else { return false }
      let writtenChangeCount = pasteboard.changeCount
      ownedChangeCount = writtenChangeCount
      return ClipboardOwnership.isCurrent(
        currentMarker: pasteboard.string(forType: Self.markerType), expectedMarker: marker,
        currentChangeCount: pasteboard.changeCount, expectedChangeCount: writtenChangeCount)
    }

    let commit: PasteCommit = { validate, dispatch in
      if let committedOutcome { return committedOutcome }
      let outcome: TargetInsertionOutcome
      if Task.isCancelled {
        outcome = .blocked(.targetUnavailable)
      } else if let reason = validate() {
        outcome = .blocked(reason)
      } else if !copyIfUnchanged() {
        outcome = .blocked(.clipboardChanged)
      } else {
        outcome = Task.isCancelled ? .blocked(.targetUnavailable) : dispatch()
      }
      committedOutcome = outcome
      return outcome
    }
    let outcome = await target?.perform(commit) ?? .blocked(.targetUnavailable)
    guard !Task.isCancelled else { return .cancelled }
    switch outcome {
    case .pasteSent:
      return .pasteSent
    case .blocked(let reason):
      guard copyIfUnchanged() else {
        return .failed("Couldn’t paste or copy—clipboard changed or unavailable.")
      }
      return .copied(reason)
    }
  }

  private static func captureSystemTarget() -> Task<TextInsertionTarget?, Never> {
    guard AXIsProcessTrusted() else { return Task { .rejected(.accessibilityPermission) } }
    // Carbon's secure-input query is not thread safe; keep every call on MainActor.
    guard !IsSecureEventInputEnabled() else { return Task { .rejected(.secureInput) } }
    guard let application = NSWorkspace.shared.frontmostApplication,
      !application.isTerminated,
      application.processIdentifier != ProcessInfo.processInfo.processIdentifier
    else { return Task { .rejected(.targetUnavailable) } }
    // Pin app, window and field synchronously at stop, before cleanup or a task hop.
    let identity = AccessibilityPasteWorker(seconds: 0.35).pinTarget(
      in: application.processIdentifier)
    return Task {
      switch identity {
      case .failure(let reason): return .rejected(reason)
      case .success(let identity):
        return await withTaskGroup(of: TextInsertionTarget.self) { group in
          group.addTask(priority: .userInitiated) {
            await AccessibilityPasteWorker(seconds: 3.25).capture(identity)
          }
          return await group.next() ?? .rejected(.targetUnavailable)
        }
      }
    }
  }
}

private final class AccessibilityPasteWorker: @unchecked Sendable {
  private let deadline: InsertionDeadline
  init(seconds: TimeInterval = 0.75) { deadline = InsertionDeadline(seconds: seconds) }
  private var shouldStop: Bool { Task.isCancelled || deadline.isExpired }

  // Immutable AX identities, accessed serially by one worker at a time.
  struct Identity: @unchecked Sendable {
    let pid: pid_t
    let application: AXUIElement
    let window: AXUIElement
    let focus: AXUIElement
  }

  private struct Snapshot: @unchecked Sendable {
    let identity: Identity
    let editor: AXUIElement
  }

  func pinTarget(in pid: pid_t) -> Result<Identity, PasteBlockReason> {
    let application = AXUIElementCreateApplication(pid)
    _ = stringAttribute(application, kAXRoleAttribute as CFString)
    guard booleanAttribute(application, kAXFrontmostAttribute as CFString) == true,
      let window = elementAttribute(application, kAXFocusedWindowAttribute as CFString),
      let focus = elementAttribute(application, kAXFocusedUIElementAttribute as CFString),
      !shouldStop
    else {
      _ = requestAccessibility(in: application)
      return .failure(.targetUnavailable)
    }
    let identity = Identity(pid: pid, application: application, window: window, focus: focus)
    return identityBlockReason(identity).map { .failure($0) } ?? .success(identity)
  }

  func capture(_ identity: Identity) async -> TextInsertionTarget {
    let result = await FocusedElementRecovery.resolve(
      targetIsCurrent: { self.identityIsCurrent(identity) },
      readFocus: { self.editorCandidate(identity) },
      requestAccessibility: { self.requestAccessibility(in: identity.application) },
      attempts: 12,
      wait: {
        guard let delay = self.deadline.remainingDelay(maximum: 0.25) else {
          throw CancellationError()
        }
        try await Task.sleep(for: .seconds(delay))
      },
      isCancelled: { self.shouldStop })
    guard let result else {
      return .rejected(identityBlockReason(identity) ?? .targetUnavailable)
    }
    switch result {
    case .failure(let reason): return .rejected(reason)
    case .success(let editor):
      let snapshot = Snapshot(identity: identity, editor: editor)
      return TextInsertionTarget { commit in
        await withTaskGroup(of: TargetInsertionOutcome.self) { group in
          group.addTask(priority: .userInitiated) {
            await AccessibilityPasteWorker().paste(into: snapshot, commit: commit)
          }
          return await group.next() ?? .blocked(.targetUnavailable)
        }
      }
    }
  }

  private func paste(into target: Snapshot, commit: @escaping PasteCommit) async
    -> TargetInsertionOutcome
  {
    // Do not synthesize releases for keys the user is holding.
    while Self.modifiersAreHeld {
      guard let delay = deadline.remainingDelay(maximum: 0.02) else {
        return .blocked(.modifiersHeld)
      }
      do { try await Task.sleep(for: .seconds(delay)) } catch { return .blocked(.modifiersHeld) }
    }
    return await commit(
      {
        guard AXIsProcessTrusted() else { return .accessibilityPermission }
        guard !self.shouldStop else { return .targetUnavailable }
        if let reason = self.identityBlockReason(target.identity) { return reason }
        guard let candidate = self.editorCandidate(target.identity) else {
          return .targetUnavailable
        }
        switch candidate {
        case .failure(let reason): return reason
        case .success(let editor):
          guard CFEqual(editor, target.editor) else { return .targetChanged }
          if let reason = self.identityBlockReason(target.identity) { return reason }
        }
        guard !IsSecureEventInputEnabled() else { return .secureInput }
        guard !Self.modifiersAreHeld else { return .modifiersHeld }
        return self.shouldStop ? .targetUnavailable : nil
      },
      {
        guard !self.shouldStop else { return .blocked(.targetUnavailable) }
        guard !IsSecureEventInputEnabled() else { return .blocked(.secureInput) }
        guard !Self.modifiersAreHeld else { return .blocked(.modifiersHeld) }
        return TargetedPasteEvent.post(to: target.identity.pid)
          ? .pasteSent : .blocked(.shortcutUnavailable)
      })
  }

  private static var modifiersAreHeld: Bool {
    let modifiers: CGEventFlags = [.maskShift, .maskControl, .maskAlternate, .maskCommand]
    return !CGEventSource.flagsState(.hidSystemState).intersection(modifiers).isEmpty
  }

  private func requestAccessibility(in application: AXUIElement) -> Bool {
    guard !shouldStop,
      booleanAttribute(application, kAXFrontmostAttribute as CFString) == true
    else { return false }
    let attribute = "AXManualAccessibility" as CFString
    guard setTimeout(on: application) else { return false }
    var settable = DarwinBoolean(false)
    if AXUIElementIsAttributeSettable(application, attribute, &settable) == .success,
      settable.boolValue
    {
      if booleanAttribute(application, attribute) == true { return true }
      guard setTimeout(on: application), !shouldStop else { return false }
      return AXUIElementSetAttributeValue(application, attribute, kCFBooleanTrue) == .success
    }
    return stringAttribute(application, kAXRoleAttribute as CFString) != nil
  }

  private func identityIsCurrent(_ target: Identity) -> Bool {
    identityBlockReason(target) == nil
  }

  private func identityBlockReason(_ target: Identity) -> PasteBlockReason? {
    guard !shouldStop,
      let frontmost = booleanAttribute(target.application, kAXFrontmostAttribute as CFString)
    else { return .targetUnavailable }
    guard frontmost else { return .targetChanged }
    guard let window = elementAttribute(target.application, kAXFocusedWindowAttribute as CFString),
      let focus = elementAttribute(target.application, kAXFocusedUIElementAttribute as CFString),
      !shouldStop
    else { return .targetUnavailable }
    return CFEqual(window, target.window) && CFEqual(focus, target.focus) ? nil : .targetChanged
  }

  private func editorCandidate(_ target: Identity) -> Result<AXUIElement, PasteBlockReason>? {
    EditorAncestry.resolve(
      startingAt: target.focus,
      traits: { self.traits(of: $0) },
      parent: { element in
        if CFEqual(element, target.application) { return .root }
        guard let parent = self.elementAttribute(element, kAXParentAttribute as CFString) else {
          return .unavailable
        }
        return .parent(parent)
      }, same: { CFEqual($0, $1) }, shouldStop: { self.shouldStop })
  }

  private func traits(of element: AXUIElement) -> TextTargetTraits {
    guard !shouldStop, let role = stringAttribute(element, kAXRoleAttribute as CFString) else {
      return TextTargetTraits()
    }
    let (subroleResult, subrole) = readAttribute(element, kAXSubroleAttribute as CFString)
    var evidence = TextTargetTraits(
      roles: [role],
      secureTextStatus: SecureTextStatus.resolve(subrole: subrole as? String, result: subroleResult)
    )
    guard evidence.secureTextStatus == .nonSecure else { return evidence }
    let enabled = optionalBoolean(element, kAXEnabledAttribute as CFString)
    let editable = optionalBoolean(element, "AXEditable" as CFString)
    guard enabled.valid, editable.valid else { return TextTargetTraits() }
    evidence.enabled = enabled.value
    evidence.editable = editable.value
    // Standard text roles need no AX mutation capability. Custom editors need
    // selection metadata and an explicit editable flag on the same element.
    if !TextTargetPolicy.textRoles.contains(role), editable.value == true {
      guard let names = attributeNames(element) else { return TextTargetTraits() }
      evidence.supportedAttributes = names
    }
    return evidence
  }

  private func optionalBoolean(_ element: AXUIElement, _ name: CFString)
    -> (valid: Bool, value: Bool?)
  {
    let (result, value) = readAttribute(element, name)
    if result == .attributeUnsupported || result == .noValue { return (true, nil) }
    guard result == .success, let value = value as? NSNumber else { return (false, nil) }
    return (true, value.boolValue)
  }

  @discardableResult
  private func setTimeout(on element: AXUIElement, maximum: Float = 0.1) -> Bool {
    guard let timeout = deadline.timeout(maximum: maximum) else { return false }
    return AXUIElementSetMessagingTimeout(element, timeout) == .success
  }

  private func readAttribute(_ element: AXUIElement, _ attribute: CFString) -> (AXError, CFTypeRef?)
  {
    AXQuery.read {
      self.setTimeout(on: element) && !self.shouldStop
    } perform: {
      var value: CFTypeRef?
      let result = AXUIElementCopyAttributeValue(element, attribute, &value)
      return (result, value)
    }
  }

  private func copyAttribute(_ element: AXUIElement, _ attribute: CFString) -> CFTypeRef? {
    let (result, value) = readAttribute(element, attribute)
    return result == .success ? value : nil
  }

  private func elementAttribute(_ element: AXUIElement, _ attribute: CFString) -> AXUIElement? {
    guard let value = copyAttribute(element, attribute),
      CFGetTypeID(value) == AXUIElementGetTypeID()
    else { return nil }
    return unsafeDowncast(value, to: AXUIElement.self)
  }

  private func stringAttribute(_ element: AXUIElement, _ attribute: CFString) -> String? {
    copyAttribute(element, attribute) as? String
  }

  private func booleanAttribute(_ element: AXUIElement, _ attribute: CFString) -> Bool? {
    (copyAttribute(element, attribute) as? NSNumber)?.boolValue
  }

  private func attributeNames(_ element: AXUIElement) -> Set<String>? {
    let (result, names) = AXQuery.read {
      self.setTimeout(on: element) && !self.shouldStop
    } perform: {
      var names: CFArray?
      let result = AXUIElementCopyAttributeNames(element, &names)
      return (result, names)
    }
    guard result == .success, let names = names as? [String] else { return nil }
    return Set(names)
  }

}

enum ClipboardOwnership {
  static func isCurrent(
    currentMarker: String?, expectedMarker: String, currentChangeCount: Int,
    expectedChangeCount: Int
  ) -> Bool {
    currentMarker == expectedMarker && currentChangeCount == expectedChangeCount
  }
}

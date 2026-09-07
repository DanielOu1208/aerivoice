import AppKit
import ApplicationServices

enum PasteDispatchStrategy: Equatable {
  case menuCommand
  case targetedShortcut
  case copyOnly
}

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

struct TextTargetTraits: Equatable {
  var roles: Set<String> = []
  var supportedAttributes: Set<String> = []
  var settableAttributes: Set<String> = []
  var secureTextStatus: SecureTextStatus = .unknown
  var enabled: Bool?
  var editable: Bool?
}

enum TextTargetPolicy {
  private static let editableRoles: Set<String> = [
    kAXTextFieldRole as String,
    kAXTextAreaRole as String,
    kAXComboBoxRole as String,
  ]

  static func permitsInsertion(_ traits: TextTargetTraits) -> Bool {
    traits.secureTextStatus == .nonSecure
  }

  static func isEditable(_ traits: TextTargetTraits) -> Bool {
    guard traits.enabled != false, traits.editable != false else { return false }
    if traits.settableAttributes.contains(kAXSelectedTextAttribute as String) { return true }
    if !traits.roles.isDisjoint(with: editableRoles) {
      return traits.editable == true
        || traits.settableAttributes.contains(kAXValueAttribute as String)
    }
    return traits.editable == true
      && traits.supportedAttributes.contains(kAXSelectedTextAttribute as String)
      && traits.supportedAttributes.contains(kAXSelectedTextRangeAttribute as String)
  }

  static func dispatchStrategy(
    for traits: TextTargetTraits, hasEnabledPasteCommand: Bool
  ) -> PasteDispatchStrategy {
    guard permitsInsertion(traits), isEditable(traits) else { return .copyOnly }
    return hasEnabledPasteCommand ? .menuCommand : .targetedShortcut
  }

}

struct PasteMenuItemTraits: Equatable {
  let commandCharacter: String?
  let virtualKey: Int?
  let modifiers: UInt32?
  let enabled: Bool
}

enum PasteMenuItemPolicy {
  static func isStandardPaste(_ traits: PasteMenuItemTraits) -> Bool {
    guard traits.enabled, traits.modifiers == 0 else { return false }
    return traits.commandCharacter?.caseInsensitiveCompare("v") == .orderedSame
      || traits.virtualKey == 9
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

/// Final validation, clipboard commit and action run synchronously on MainActor.
/// There is no actor hop between the last target check and the action.
typealias PasteCommit =
  @MainActor @Sendable (
    @MainActor @Sendable () -> Bool, @MainActor @Sendable () -> TargetInsertionOutcome
  ) -> TargetInsertionOutcome

/// Immutable, session-owned capability. AX handles never escape into the coordinator.
struct TextInsertionTarget: Sendable {
  let id = UUID()
  let perform:
    @Sendable (
      String, @escaping PasteCommit
    ) async -> TargetInsertionOutcome
}

enum TargetInsertionOutcome: Equatable, Sendable {
  case inserted
  case pasteRequested
  case unavailable
  case uncertain
}

@MainActor
final class TextInsertionService: TextInserting {
  private static let markerType = NSPasteboard.PasteboardType(
    "com.danielou.AeriVoice.clipboard-owner")
  // Shared across instances, but isolated per pasteboard (tests use private boards).
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

  func captureTarget() -> Task<TextInsertionTarget?, Never> { capture() }

  func insert(_ text: String, into target: TextInsertionTarget?) async -> InsertionResult {
    guard !Task.isCancelled else { return .cancelled }
    guard Self.activeBoards.insert(pasteboard.name).inserted else {
      return .failed("Another insertion is still finishing—nothing copied.")
    }
    defer { Self.activeBoards.remove(pasteboard.name) }
    let initialChangeCount = pasteboard.changeCount
    let marker = UUID().uuidString
    var ownedChangeCount: Int?

    // Write only at the action boundary, after AX validation. Calling again checks
    // ownership rather than overwriting a user's intervening copy.
    let authorizePaste: @MainActor @Sendable () -> Bool = { [self] in
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
      ownedChangeCount = pasteboard.changeCount
      return true
    }

    let commit: PasteCommit = { validate, dispatch in
      guard !Task.isCancelled, validate(), authorizePaste() else { return .unavailable }
      return dispatch()
    }
    let outcome = await target?.perform(text, commit) ?? .unavailable
    guard !Task.isCancelled else { return .cancelled }
    switch outcome {
    case .inserted:
      return .inserted
    case .pasteRequested, .uncertain:
      let kept = authorizePaste()
      return .unconfirmed(
        kept
          ? "Insertion unconfirmed—check destination. Text is on the clipboard."
          : "Insertion unconfirmed—check destination. Clipboard changed or unavailable.")
    case .unavailable:
      guard authorizePaste() else {
        return .failed("Couldn’t insert or copy—clipboard changed or unavailable.")
      }
      return .copied("Couldn’t insert into the original field—copied instead.")
    }
  }

  private static func captureSystemTarget() -> Task<TextInsertionTarget?, Never> {
    // Snapshot the PID synchronously at stop, not after cleanup or a task hop.
    guard AXIsProcessTrusted(), let application = NSWorkspace.shared.frontmostApplication,
      !application.isTerminated,
      application.processIdentifier != ProcessInfo.processInfo.processIdentifier
    else { return Task { nil } }
    let pid = application.processIdentifier
    return Task {
      await withTaskGroup(of: TextInsertionTarget?.self) { group in
        group.addTask(priority: .userInitiated) {
          await AccessibilityPasteWorker(seconds: 3.25).capture(in: pid)
        }
        return await group.next() ?? nil
      }
    }
  }
}

private final class AccessibilityPasteWorker: @unchecked Sendable {
  private let deadline: InsertionDeadline

  init(seconds: TimeInterval = 0.75) { deadline = InsertionDeadline(seconds: seconds) }
  private let menuSearchLimit = 180
  private let menuSearchDuration: CFTimeInterval = 0.2
  private var shouldStop: Bool { Task.isCancelled || deadline.isExpired }

  // AXUIElement references are immutable identities. Each worker uses them only
  // serially on its task; the snapshot carries no mutable state across tasks.
  private struct Snapshot: @unchecked Sendable {
    let pid: pid_t
    let application: AXUIElement
    let focus: AXUIElement
    let editor: AXUIElement
  }

  private struct MenuItem: @unchecked Sendable {
    let element: AXUIElement
  }

  func capture(in processIdentifier: pid_t) async -> TextInsertionTarget? {
    let application = AXUIElementCreateApplication(processIdentifier)
    // Chromium uses this role read to activate basic/native accessibility.
    _ = stringAttribute(application, kAXRoleAttribute as CFString)
    guard let pinnedFocus = elementAttribute(application, kAXFocusedUIElementAttribute as CFString)
    else {
      _ = requestAccessibility(in: application)
      return nil  // No stop-time identity: never substitute a later field.
    }
    guard
      let snapshot = await FocusedElementRecovery.resolve(
        targetIsCurrent: {
          guard !self.shouldStop,
            self.booleanAttribute(application, kAXFrontmostAttribute as CFString) == true,
            let current = self.elementAttribute(
              application, kAXFocusedUIElementAttribute as CFString)
          else { return false }
          return CFEqual(current, pinnedFocus)
        },
        readFocus: { () -> Snapshot? in
          guard
            let focus = self.elementAttribute(
              application, kAXFocusedUIElementAttribute as CFString),
            CFEqual(focus, pinnedFocus),
            let editor = self.editableCandidate(startingAt: focus, application: application)
          else { return nil }
          return Snapshot(
            pid: processIdentifier, application: application, focus: focus, editor: editor)
        },
        requestAccessibility: { self.requestAccessibility(in: application) },
        attempts: 12,
        wait: {
          guard let delay = self.deadline.remainingDelay(maximum: 0.25) else {
            throw CancellationError()
          }
          try await Task.sleep(for: .seconds(delay))
        },
        isCancelled: { self.shouldStop })
    else { return nil }
    return TextInsertionTarget { text, authorizePaste in
      await withTaskGroup(of: TargetInsertionOutcome.self) { group in
        group.addTask(priority: .userInitiated) {
          await AccessibilityPasteWorker().insert(
            text, into: snapshot, authorizePaste: authorizePaste)
        }
        return await group.next() ?? .unavailable
      }
    }
  }

  private func insert(
    _ text: String, into target: Snapshot,
    authorizePaste: @escaping PasteCommit
  ) async -> TargetInsertionOutcome {
    guard targetIsCurrent(target) else { return .unavailable }
    let evidence = traits(of: target.editor)
    guard TextTargetPolicy.permitsInsertion(evidence), TextTargetPolicy.isEditable(evidence) else {
      return .unavailable
    }
    // Prefer replacing only the selection, never the entire AXValue. This path
    // does not depend on the global clipboard or a queued keyboard event.
    if evidence.settableAttributes.contains(kAXSelectedTextAttribute as String) {
      guard focusIsCurrent(target), setTimeout(on: target.editor, maximum: 0.2), !shouldStop else {
        return .unavailable
      }
      let result = AXUIElementSetAttributeValue(
        target.editor, kAXSelectedTextAttribute as CFString, text as CFString)
      // A timed-out mutation may already have happened. Never retry it as Paste.
      return AXMutationOutcome.resolve(result, success: .inserted)
    }

    let menu = enabledPasteMenuItem(in: target.application).map { MenuItem(element: $0) }
    let strategy = TextTargetPolicy.dispatchStrategy(
      for: evidence, hasEnabledPasteCommand: menu != nil)
    guard strategy != .copyOnly else { return .unavailable }
    return await authorizePaste(
      {
        guard !self.shouldStop else { return false }
        if let menu, !self.pasteMenuItemIsEnabledStandardPaste(menu.element) { return false }
        return self.targetIsCurrent(target)
      },
      {
        guard !self.shouldStop else { return .unavailable }
        if let menu {
          guard self.setTimeout(on: menu.element, maximum: 0.2), !self.shouldStop else {
            return .unavailable
          }
          // Accepted request, not proof of clipboard consumption. Never retry.
          return AXMutationOutcome.resolve(
            AXUIElementPerformAction(menu.element, kAXPressAction as CFString),
            success: .pasteRequested)
        }
        return TargetedPasteEvent.post(to: target.pid) ? .pasteRequested : .unavailable
      })
  }

  private func requestAccessibility(in application: AXUIElement) -> Bool {
    guard !shouldStop,
      booleanAttribute(application, kAXFrontmostAttribute as CFString) == true
    else { return false }
    // Electron documents this opt-in. Do not toggle the undocumented/debounced
    // AXEnhancedUserInterface flag or assume that a successful setter is immediate.
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
    // Chromium's generic assistive-technology activation path is a role read.
    return stringAttribute(application, kAXRoleAttribute as CFString) != nil
  }

  private func focusIsCurrent(_ target: Snapshot) -> Bool {
    guard !shouldStop,
      booleanAttribute(target.application, kAXFrontmostAttribute as CFString) == true,
      let focus = elementAttribute(target.application, kAXFocusedUIElementAttribute as CFString)
    else { return false }
    return !shouldStop && CFEqual(focus, target.focus)
  }

  private func targetIsCurrent(_ target: Snapshot) -> Bool {
    guard focusIsCurrent(target),
      let editor = editableCandidate(startingAt: target.focus, application: target.application)
    else { return false }
    return !shouldStop && CFEqual(editor, target.editor) && focusIsCurrent(target)
  }

  private func editableCandidate(
    startingAt focus: AXUIElement, application: AXUIElement
  ) -> AXUIElement? {
    EditorAncestry.resolve(
      startingAt: focus,
      traits: { self.traits(of: $0) },
      parent: { element in
        if CFEqual(element, application) { return .root }
        guard let parent = self.elementAttribute(element, kAXParentAttribute as CFString) else {
          return .unavailable
        }
        return .parent(parent)
      }, same: { CFEqual($0, $1) }, shouldStop: { self.shouldStop })
  }

  private func traits(of element: AXUIElement) -> TextTargetTraits {
    var evidence = TextTargetTraits()
    guard !shouldStop else { return evidence }
    if let role = stringAttribute(element, kAXRoleAttribute as CFString) {
      evidence.roles.insert(role)
    }
    evidence.secureTextStatus = secureTextStatus(of: element)
    guard TextTargetPolicy.permitsInsertion(evidence) else { return evidence }
    // Containers still participate in the security walk, but need no editor probes.
    let containers: Set<String> = [
      kAXApplicationRole as String, kAXWindowRole as String,
      kAXScrollAreaRole as String, kAXSplitGroupRole as String,
    ]
    if !evidence.roles.isDisjoint(with: containers) { return evidence }
    evidence.enabled = booleanAttribute(element, kAXEnabledAttribute as CFString)
    evidence.editable = booleanAttribute(element, "AXEditable" as CFString)
    if let names = attributeNames(element) {
      evidence.supportedAttributes = names
      if names.contains(kAXEnabledAttribute as String), evidence.enabled == nil {
        return TextTargetTraits()
      }
    }
    for attribute in [kAXValueAttribute, kAXSelectedTextAttribute] {
      guard setTimeout(on: element), !shouldStop else { return TextTargetTraits() }
      var settable = DarwinBoolean(false)
      if AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) == .success,
        settable.boolValue
      {
        evidence.settableAttributes.insert(attribute as String)
      }
    }
    return evidence
  }

  private func secureTextStatus(of element: AXUIElement) -> SecureTextStatus {
    let (result, value) = readAttribute(element, kAXSubroleAttribute as CFString)
    return SecureTextStatus.resolve(subrole: value as? String, result: result)
  }

  private func enabledPasteMenuItem(in applicationElement: AXUIElement) -> AXUIElement? {
    guard let menuBar = elementAttribute(applicationElement, kAXMenuBarAttribute as CFString) else {
      return nil
    }
    let deadline = CACurrentMediaTime() + menuSearchDuration
    var visited = 0

    func find(in element: AXUIElement, depth: Int) -> AXUIElement? {
      guard !shouldStop, depth <= 5, visited < menuSearchLimit,
        CACurrentMediaTime() < deadline
      else {
        return nil
      }
      visited += 1

      if pasteMenuItemIsEnabledStandardPaste(element, requireEnabled: false) { return element }
      for child in children(of: element) {
        if let match = find(in: child, depth: depth + 1) { return match }
      }
      return nil
    }

    return find(in: menuBar, depth: 0)
  }

  private func pasteMenuItemIsEnabledStandardPaste(
    _ element: AXUIElement, requireEnabled: Bool = true
  ) -> Bool {
    guard stringAttribute(element, kAXRoleAttribute as CFString) == kAXMenuItemRole as String else {
      return false
    }
    return PasteMenuItemPolicy.isStandardPaste(
      PasteMenuItemTraits(
        commandCharacter: stringAttribute(element, kAXMenuItemCmdCharAttribute as CFString),
        virtualKey: integerAttribute(element, kAXMenuItemCmdVirtualKeyAttribute as CFString),
        modifiers: integerAttribute(element, kAXMenuItemCmdModifiersAttribute as CFString).map {
          UInt32($0)
        },
        enabled: !requireEnabled
          || booleanAttribute(element, kAXEnabledAttribute as CFString) == true))
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

  private func integerAttribute(_ element: AXUIElement, _ attribute: CFString) -> Int? {
    (copyAttribute(element, attribute) as? NSNumber)?.intValue
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

  private func children(of element: AXUIElement) -> [AXUIElement] {
    guard let value = copyAttribute(element, kAXChildrenAttribute as CFString),
      let children = value as? [AXUIElement]
    else { return [] }
    return children
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

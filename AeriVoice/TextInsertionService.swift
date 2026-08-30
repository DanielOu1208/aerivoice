import AppKit
import ApplicationServices

enum PasteDispatchStrategy: Equatable {
  case menuCommand
  case targetedShortcut
  case copyOnly
}

struct TextTargetTraits: Equatable {
  var roles: Set<String> = []
  var subroles: Set<String> = []
  var supportedAttributes: Set<String> = []
  var settableAttributes: Set<String> = []
}

enum TextTargetPolicy {
  private static let editableRoles: Set<String> = [
    kAXTextFieldRole as String,
    kAXTextAreaRole as String,
    kAXComboBoxRole as String,
  ]

  static func isSecure(_ traits: TextTargetTraits) -> Bool {
    traits.subroles.contains(kAXSecureTextFieldSubrole as String)
  }

  static func isEditable(_ traits: TextTargetTraits) -> Bool {
    if !traits.roles.isDisjoint(with: editableRoles) { return true }
    if hasSettableTextAttribute(traits) { return true }
    return traits.supportedAttributes.contains(kAXSelectedTextAttribute as String)
      && traits.supportedAttributes.contains(kAXSelectedTextRangeAttribute as String)
      && traits.supportedAttributes.contains(kAXNumberOfCharactersAttribute as String)
  }

  static func dispatchStrategy(
    for traits: TextTargetTraits, hasEnabledPasteCommand: Bool
  ) -> PasteDispatchStrategy {
    guard !isSecure(traits), isEditable(traits) else { return .copyOnly }
    return hasEnabledPasteCommand ? .menuCommand : .targetedShortcut
  }

  private static func hasSettableTextAttribute(_ traits: TextTargetTraits) -> Bool {
    traits.settableAttributes.contains(kAXValueAttribute as String)
      || traits.settableAttributes.contains(kAXSelectedTextAttribute as String)
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

enum PasteActionDispatcher {
  static func dispatch(
    strategy: PasteDispatchStrategy,
    targetIsCurrent: () -> Bool,
    pressMenuItem: () -> Bool,
    postTargetedShortcut: () -> Bool,
    isCancelled: () -> Bool = { Task.isCancelled }
  ) -> Bool {
    guard !isCancelled() else { return false }
    switch strategy {
    case .menuCommand:
      guard targetIsCurrent(), !isCancelled() else { return false }
      return pressMenuItem()
    case .targetedShortcut:
      guard targetIsCurrent(), !isCancelled() else { return false }
      return postTargetedShortcut()
    case .copyOnly:
      return false
    }
  }
}

struct TextInsertionService: TextInserting {
  private static let markerType = NSPasteboard.PasteboardType(
    "com.danielou.AeriVoice.clipboard-owner")
  private static let copiedWarning = "Couldn’t insert—copied instead."
  private static let copyFailedWarning = "Couldn’t insert or copy the transcript."

  @MainActor
  func insert(_ text: String) async -> InsertionResult {
    let pasteboard = NSPasteboard.general
    let previous = PasteboardSnapshot(pasteboard: pasteboard)
    let marker = UUID().uuidString
    guard write(text, marker: marker, to: pasteboard) else {
      pasteboard.clearContents()
      let copied = pasteboard.setString(text, forType: .string)
      return .copied(copied ? Self.copiedWarning : Self.copyFailedWarning)
    }
    let ownershipChangeCount = pasteboard.changeCount

    guard AXIsProcessTrusted() else {
      return .copied(Self.copiedWarning)
    }

    await Task.yield()
    guard !Task.isCancelled, let processIdentifier = frontmostTargetProcessIdentifier() else {
      return .copied(Self.copiedWarning)
    }
    let dispatched = await withTaskGroup(of: Bool.self) { group in
      group.addTask(priority: .userInitiated) {
        AccessibilityPasteWorker().paste(into: processIdentifier)
      }
      return await group.next() ?? false
    }
    guard !Task.isCancelled, dispatched else {
      return .copied(Self.copiedWarning)
    }

    Task { @MainActor in
      try? await Task.sleep(for: .seconds(1))
      guard
        ClipboardOwnership.shouldRestore(
          currentMarker: pasteboard.string(forType: Self.markerType), expectedMarker: marker,
          currentChangeCount: pasteboard.changeCount, expectedChangeCount: ownershipChangeCount)
      else { return }
      previous.restore(to: pasteboard)
    }
    return .inserted
  }

  @MainActor
  private func write(_ text: String, marker: String, to pasteboard: NSPasteboard) -> Bool {
    let item = NSPasteboardItem()
    guard item.setString(text, forType: .string), item.setString(marker, forType: Self.markerType)
    else { return false }
    pasteboard.clearContents()
    return pasteboard.writeObjects([item])
  }

  @MainActor
  private func frontmostTargetProcessIdentifier() -> pid_t? {
    guard let application = NSWorkspace.shared.frontmostApplication,
      !application.isTerminated,
      application.processIdentifier != ProcessInfo.processInfo.processIdentifier
    else { return nil }
    return application.processIdentifier
  }
}

private final class AccessibilityPasteWorker: @unchecked Sendable {
  private let queryTimeout: Float = 0.1
  private let actionTimeout: Float = 0.2
  private let menuSearchLimit = 180
  private let menuSearchDuration: CFTimeInterval = 0.25

  func paste(into processIdentifier: pid_t) -> Bool {
    guard !Task.isCancelled else { return false }
    let applicationElement = AXUIElementCreateApplication(processIdentifier)
    setTimeout(on: applicationElement)
    guard booleanAttribute(applicationElement, kAXFrontmostAttribute as CFString) == true,
      let focusedElement = elementAttribute(
        applicationElement, kAXFocusedUIElementAttribute as CFString),
      let editor = editableCandidate(startingAt: focusedElement)
    else { return false }

    let pasteMenuItem = enabledPasteMenuItem(in: applicationElement)
    guard targetIsCurrent(
      applicationElement: applicationElement, focusedElement: focusedElement, editor: editor)
    else { return false }

    let strategy = TextTargetPolicy.dispatchStrategy(
      for: traits(of: editor), hasEnabledPasteCommand: pasteMenuItem != nil)
    if strategy == .menuCommand {
      guard let pasteMenuItem, pasteMenuItemIsEnabledStandardPaste(pasteMenuItem) else {
        return false
      }
    }
    return PasteActionDispatcher.dispatch(
      strategy: strategy,
      targetIsCurrent: {
        self.targetIsCurrent(
          applicationElement: applicationElement, focusedElement: focusedElement, editor: editor)
      },
      pressMenuItem: {
        guard let pasteMenuItem else { return false }
        AXUIElementSetMessagingTimeout(pasteMenuItem, self.actionTimeout)
        guard !Task.isCancelled else { return false }
        return AXUIElementPerformAction(pasteMenuItem, kAXPressAction as CFString) == .success
      },
      postTargetedShortcut: {
        guard !Task.isCancelled else { return false }
        return TargetedPasteEvent.post(to: processIdentifier)
      })
  }

  private func targetIsCurrent(
    applicationElement: AXUIElement, focusedElement: AXUIElement, editor: AXUIElement
  ) -> Bool {
    guard booleanAttribute(applicationElement, kAXFrontmostAttribute as CFString) == true,
      let currentFocus = elementAttribute(
        applicationElement, kAXFocusedUIElementAttribute as CFString),
      CFEqual(currentFocus, focusedElement),
      let currentEditor = editableCandidate(startingAt: currentFocus)
    else { return false }
    return CFEqual(currentEditor, editor)
  }

  private func editableCandidate(startingAt focusedElement: AXUIElement) -> AXUIElement? {
    var candidate: AXUIElement?
    var current: AXUIElement? = focusedElement
    var depth = 0

    while let element = current, depth < 8 {
      guard !Task.isCancelled else { return nil }
      let traits = traits(of: element)
      if TextTargetPolicy.isSecure(traits) { return nil }
      if candidate == nil, TextTargetPolicy.isEditable(traits) { candidate = element }

      let parent = elementAttribute(element, kAXParentAttribute as CFString)
      if let parent, CFEqual(parent, element) { break }
      current = parent
      depth += 1
    }
    return candidate
  }

  private func traits(of element: AXUIElement) -> TextTargetTraits {
    var traits = TextTargetTraits()
    if let role = stringAttribute(element, kAXRoleAttribute as CFString) {
      traits.roles.insert(role)
    }
    if let subrole = stringAttribute(element, kAXSubroleAttribute as CFString) {
      traits.subroles.insert(subrole)
    }
    if let names = attributeNames(element) {
      traits.supportedAttributes = names
    }
    for attribute in [kAXValueAttribute, kAXSelectedTextAttribute] {
      var settable = DarwinBoolean(false)
      setTimeout(on: element)
      if AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) == .success,
        settable.boolValue
      {
        traits.settableAttributes.insert(attribute as String)
      }
    }
    return traits
  }

  private func enabledPasteMenuItem(in applicationElement: AXUIElement) -> AXUIElement? {
    guard let menuBar = elementAttribute(applicationElement, kAXMenuBarAttribute as CFString) else {
      return nil
    }
    let deadline = CACurrentMediaTime() + menuSearchDuration
    var visited = 0

    func find(in element: AXUIElement, depth: Int) -> AXUIElement? {
      guard !Task.isCancelled, depth <= 5, visited < menuSearchLimit,
        CACurrentMediaTime() < deadline
      else {
        return nil
      }
      visited += 1

      if pasteMenuItemIsEnabledStandardPaste(element) { return element }
      for child in children(of: element) {
        if let match = find(in: child, depth: depth + 1) { return match }
      }
      return nil
    }

    return find(in: menuBar, depth: 0)
  }

  private func pasteMenuItemIsEnabledStandardPaste(_ element: AXUIElement) -> Bool {
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
        enabled: booleanAttribute(element, kAXEnabledAttribute as CFString) ?? false))
  }

  private func setTimeout(on element: AXUIElement) {
    AXUIElementSetMessagingTimeout(element, queryTimeout)
  }

  private func copyAttribute(_ element: AXUIElement, _ attribute: CFString) -> CFTypeRef? {
    setTimeout(on: element)
    for attempt in 0..<2 {
      guard !Task.isCancelled else { return nil }
      var value: CFTypeRef?
      let result = AXUIElementCopyAttributeValue(element, attribute, &value)
      if result == .success { return value }
      if result != .cannotComplete || attempt == 1 { return nil }
    }
    return nil
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
    setTimeout(on: element)
    for attempt in 0..<2 {
      guard !Task.isCancelled else { return nil }
      var names: CFArray?
      let result = AXUIElementCopyAttributeNames(element, &names)
      if result == .success, let names = names as? [String] { return Set(names) }
      if result != .cannotComplete || attempt == 1 { return nil }
    }
    return nil
  }

  private func children(of element: AXUIElement) -> [AXUIElement] {
    guard let value = copyAttribute(element, kAXChildrenAttribute as CFString),
      let children = value as? [AXUIElement]
    else { return [] }
    return children
  }
}

enum ClipboardOwnership {
  static func shouldRestore(
    currentMarker: String?, expectedMarker: String, currentChangeCount: Int,
    expectedChangeCount: Int
  ) -> Bool {
    currentMarker == expectedMarker && currentChangeCount == expectedChangeCount
  }
}

private struct PasteboardSnapshot {
  let items: [[NSPasteboard.PasteboardType: Data]]

  init(pasteboard: NSPasteboard) {
    items = (pasteboard.pasteboardItems ?? []).map { item in
      Dictionary(
        uniqueKeysWithValues: item.types.compactMap { type in
          item.data(forType: type).map { (type, $0) }
        })
    }
  }

  func restore(to pasteboard: NSPasteboard) {
    pasteboard.clearContents()
    let restored = items.map { values -> NSPasteboardItem in
      let item = NSPasteboardItem()
      for (type, data) in values { item.setData(data, forType: type) }
      return item
    }
    pasteboard.writeObjects(restored)
  }
}

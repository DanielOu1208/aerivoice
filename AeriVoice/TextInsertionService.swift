import AppKit
import ApplicationServices

struct TextInsertionService: TextInserting {
  private static let markerType = NSPasteboard.PasteboardType(
    "com.danielou.AeriVoice.clipboard-owner")

  @MainActor
  func insert(_ text: String) async -> InsertionResult {
    let pasteboard = NSPasteboard.general
    let previous = PasteboardSnapshot(pasteboard: pasteboard)
    let marker = UUID().uuidString
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
    pasteboard.setString(marker, forType: Self.markerType)
    let ownershipChangeCount = pasteboard.changeCount

    guard AXIsProcessTrusted(), let focused = focusedElement(), isEditable(focused),
      !isSecure(focused), GlobalShortcutMonitor.postPaste()
    else {
      return .copied("Couldn’t insert—copied instead.")
    }

    Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(800))
      guard
        ClipboardOwnership.shouldRestore(
          currentMarker: pasteboard.string(forType: Self.markerType), expectedMarker: marker,
          currentChangeCount: pasteboard.changeCount, expectedChangeCount: ownershipChangeCount)
      else { return }
      previous.restore(to: pasteboard)
    }
    return .inserted
  }

  private func focusedElement() -> AXUIElement? {
    let system = AXUIElementCreateSystemWide()
    var value: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &value)
        == .success,
      let value
    else { return nil }
    return unsafeDowncast(value, to: AXUIElement.self)
  }

  private func isEditable(_ element: AXUIElement) -> Bool {
    var settable = DarwinBoolean(false)
    if AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
      == .success,
      settable.boolValue
    {
      return true
    }
    var roleValue: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue) == .success,
      let role = roleValue as? String
    else { return false }
    return [kAXTextFieldRole as String, kAXTextAreaRole as String, kAXComboBoxRole as String]
      .contains(role)
  }

  private func isSecure(_ element: AXUIElement) -> Bool {
    var value: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &value) == .success,
      let subrole = value as? String
    else { return false }
    return subrole == kAXSecureTextFieldSubrole as String
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

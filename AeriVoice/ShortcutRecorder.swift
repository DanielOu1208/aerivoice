import AppKit
import SwiftUI

struct ShortcutRecorder: NSViewRepresentable {
  let current: ShortcutDefinition?
  let onCapture: (ShortcutDefinition) -> Void

  func makeNSView(context: Context) -> ShortcutRecorderNSView {
    let view = ShortcutRecorderNSView()
    view.onCapture = onCapture
    view.displayName = current?.displayName ?? "Click and press a shortcut"
    return view
  }

  func updateNSView(_ nsView: ShortcutRecorderNSView, context: Context) {
    nsView.onCapture = onCapture
    nsView.displayName = current?.displayName ?? "Click and press a shortcut"
  }
}

final class ShortcutRecorderNSView: NSView {
  var onCapture: ((ShortcutDefinition) -> Void)?
  var displayName = "Click and press a shortcut" { didSet { needsDisplay = true } }
  private var capturedModifierFlags: NSEvent.ModifierFlags = []

  override var acceptsFirstResponder: Bool { true }
  override var intrinsicContentSize: NSSize { NSSize(width: 250, height: 34) }

  override func mouseDown(with event: NSEvent) {
    window?.makeFirstResponder(self)
    needsDisplay = true
  }

  override func becomeFirstResponder() -> Bool {
    needsDisplay = true
    return true
  }

  override func resignFirstResponder() -> Bool {
    capturedModifierFlags = []
    needsDisplay = true
    return true
  }

  override func keyDown(with event: NSEvent) {
    if event.keyCode == 53 {
      capturedModifierFlags = []
      window?.makeFirstResponder(nil)
      return
    }
    capturedModifierFlags = []
    let flags = event.modifierFlags.intersection([.command, .control, .option, .shift, .function])
    let name = Self.name(
      keyCode: event.keyCode, characters: event.charactersIgnoringModifiers, flags: flags)
    commit(
      ShortcutDefinition(keyCode: event.keyCode, modifiers: UInt(flags.rawValue), displayName: name)
    )
  }

  override func flagsChanged(with event: NSEvent) {
    let flags = event.modifierFlags.intersection([.command, .control, .option, .shift, .function])
    captureModifierFlags(flags)
  }

  func captureModifierFlags(_ flags: NSEvent.ModifierFlags) {
    if !flags.isEmpty {
      capturedModifierFlags.formUnion(flags)
    } else if !capturedModifierFlags.isEmpty {
      let name = Self.modifierSymbols(capturedModifierFlags)
      commit(
        ShortcutDefinition(
          keyCode: 0, modifiers: UInt(capturedModifierFlags.rawValue), displayName: name,
          isModifierOnly: true))
    }
  }

  override func draw(_ dirtyRect: NSRect) {
    let active = window?.firstResponder === self
    let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
    (active ? NSColor.controlAccentColor.withAlphaComponent(0.18) : NSColor.controlBackgroundColor)
      .setFill()
    path.fill()
    (active ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
    path.stroke()
    let attributes: [NSAttributedString.Key: Any] = [
      .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .medium),
      .foregroundColor: NSColor.labelColor,
    ]
    let value = NSAttributedString(
      string: active ? "Press shortcut…" : displayName, attributes: attributes)
    value.draw(
      at: CGPoint(
        x: (bounds.width - value.size().width) / 2, y: (bounds.height - value.size().height) / 2))
  }

  private static func name(keyCode: UInt16, characters: String?, flags: NSEvent.ModifierFlags)
    -> String
  {
    let key =
      characters?.uppercased().isEmpty == false ? characters!.uppercased() : "Key \(keyCode)"
    return modifierSymbols(flags) + key
  }

  private static func modifierSymbols(_ flags: NSEvent.ModifierFlags) -> String {
    var value = ""
    if flags.contains(.control) { value += "⌃" }
    if flags.contains(.option) { value += "⌥" }
    if flags.contains(.shift) { value += "⇧" }
    if flags.contains(.command) { value += "⌘" }
    if flags.contains(.function) { value += "fn" }
    return value
  }

  private func commit(_ definition: ShortcutDefinition) {
    capturedModifierFlags = []
    displayName = definition.displayName
    onCapture?(definition)
    window?.makeFirstResponder(nil)
    needsDisplay = true
  }
}

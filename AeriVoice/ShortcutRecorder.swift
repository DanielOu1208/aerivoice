import AppKit
import SwiftUI

struct ShortcutRecorder: NSViewRepresentable {
  let current: ShortcutDefinition?
  var distinguishModifierSides = false
  var captureRequestID: UUID? = nil
  var onCaptureStart: () -> Void = {}
  var onCaptureCancel: () -> Void = {}
  var onCaptureEnd: () -> Void = {}
  let onCapture: (ShortcutDefinition) -> Void

  func makeNSView(context: Context) -> ShortcutRecorderNSView {
    let view = ShortcutRecorderNSView()
    configure(view)
    return view
  }

  func updateNSView(_ nsView: ShortcutRecorderNSView, context: Context) {
    configure(nsView)
  }

  private func configure(_ view: ShortcutRecorderNSView) {
    view.onCapture = onCapture
    view.onCaptureStart = onCaptureStart
    view.onCaptureCancel = onCaptureCancel
    view.onCaptureEnd = onCaptureEnd
    view.distinguishModifierSides = distinguishModifierSides
    view.displayName = current?.displayName ?? "Click and press a shortcut"
    view.requestCapture(captureRequestID)
  }

  static func dismantleNSView(_ nsView: ShortcutRecorderNSView, coordinator: ()) {
    nsView.cancelCapture()
  }
}

final class ShortcutRecorderNSView: NSView {
  var onCapture: ((ShortcutDefinition) -> Void)?
  var onCaptureStart: (() -> Void)?
  var onCaptureCancel: (() -> Void)?
  var onCaptureEnd: (() -> Void)?
  var distinguishModifierSides = false
  private(set) var isCapturing = false
  private var captureRequestID: UUID?
  private var capturedModifierSides: ShortcutModifierSides = []
  var displayName = "Click and press a shortcut" { didSet { needsDisplay = true } }
  private var capturedModifierFlags: NSEvent.ModifierFlags = []

  override func isAccessibilityElement() -> Bool { true }
  override func accessibilityRole() -> NSAccessibility.Role? { .button }
  override func accessibilityLabel() -> String? { "Activation shortcut" }
  override func accessibilityValue() -> Any? { isCapturing ? "Press shortcut…" : displayName }
  override func accessibilityHelp() -> String? {
    "Press to record a keyboard shortcut. Press Escape to cancel."
  }
  override func accessibilityPerformPress() -> Bool { window?.makeFirstResponder(self) ?? false }

  override var acceptsFirstResponder: Bool { true }
  override var intrinsicContentSize: NSSize { NSSize(width: 250, height: 34) }

  override func viewWillMove(toWindow newWindow: NSWindow?) {
    if let window {
      NotificationCenter.default.removeObserver(
        self, name: NSWindow.didResignKeyNotification, object: window)
    }
    if newWindow == nil { cancelCapture() }
    super.viewWillMove(toWindow: newWindow)
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if let window {
      NotificationCenter.default.addObserver(
        self, selector: #selector(windowResignedKey),
        name: NSWindow.didResignKeyNotification, object: window)
    }
  }

  @objc private func windowResignedKey() {
    cancelCapture()
    if window?.firstResponder === self { window?.makeFirstResponder(nil) }
  }

  override func mouseDown(with event: NSEvent) {
    window?.makeFirstResponder(self)
    needsDisplay = true
  }

  override func becomeFirstResponder() -> Bool {
    beginCapture()
    needsDisplay = true
    return true
  }

  override func resignFirstResponder() -> Bool {
    cancelCapture()
    needsDisplay = true
    return true
  }

  override func keyDown(with event: NSEvent) {
    if event.keyCode == 53 {
      cancelCapture()
      window?.makeFirstResponder(nil)
      return
    }
    guard !event.isARepeat else { return }
    let sides = sides(in: event.modifierFlags)
    let flags = event.modifierFlags.intersection([.command, .control, .option, .shift, .function])
    let name = Self.name(
      keyCode: event.keyCode, characters: event.charactersIgnoringModifiers, flags: flags,
      sides: sides)
    commit(
      ShortcutDefinition(
        keyCode: event.keyCode, modifiers: UInt(flags.rawValue), displayName: name,
        modifierSides: sides)
    )
  }

  override func flagsChanged(with event: NSEvent) {
    captureModifierFlags(event.modifierFlags)
  }

  func captureModifierFlags(_ rawFlags: NSEvent.ModifierFlags) {
    beginCapture()
    let flags = rawFlags.intersection([.command, .control, .option, .shift, .function])
    if let sides = sides(in: rawFlags) { capturedModifierSides.formUnion(sides) }
    if !flags.isEmpty {
      capturedModifierFlags.formUnion(flags)
    } else if !capturedModifierFlags.isEmpty {
      let sides = capturedModifierSides.isEmpty ? nil : capturedModifierSides
      let name = Self.modifierSymbols(capturedModifierFlags, sides: sides)
      commit(
        ShortcutDefinition(
          keyCode: 0, modifiers: UInt(capturedModifierFlags.rawValue), displayName: name,
          isModifierOnly: true, modifierSides: sides))
    }
  }

  override func draw(_ dirtyRect: NSRect) {
    let active = isCapturing
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

  private static func name(
    keyCode: UInt16, characters: String?, flags: NSEvent.ModifierFlags,
    sides: ShortcutModifierSides? = nil
  )
    -> String
  {
    let key =
      characters?.uppercased().isEmpty == false ? characters!.uppercased() : "Key \(keyCode)"
    return modifierSymbols(flags, sides: sides) + key
  }

  private static func modifierSymbols(
    _ flags: NSEvent.ModifierFlags, sides: ShortcutModifierSides? = nil
  ) -> String {
    var value = ""
    if flags.contains(.control) { value += "⌃" }
    if flags.contains(.option) {
      if let sides, !sides.intersection(.option).isEmpty {
        if sides.contains(.leftOption) { value += "L⌥" }
        if sides.contains(.rightOption) { value += "R⌥" }
      } else {
        value += "⌥"
      }
    }
    if flags.contains(.shift) { value += "⇧" }
    if flags.contains(.command) {
      if let sides, !sides.intersection(.command).isEmpty {
        if sides.contains(.leftCommand) { value += "L⌘" }
        if sides.contains(.rightCommand) { value += "R⌘" }
      } else {
        value += "⌘"
      }
    }
    if flags.contains(.function) { value += "fn" }
    return value
  }

  func requestCapture(_ id: UUID?) {
    guard captureRequestID != id else { return }
    captureRequestID = id
    guard let id else { return }
    DispatchQueue.main.async { [weak self] in
      guard let self, self.captureRequestID == id else { return }
      self.window?.makeFirstResponder(self)
    }
  }

  func beginCapture() {
    guard !isCapturing else { return }
    isCapturing = true
    capturedModifierFlags = []
    capturedModifierSides = []
    onCaptureStart?()
    needsDisplay = true
  }

  func cancelCapture() {
    guard isCapturing else { return }
    finishCapture()
    onCaptureCancel?()
    onCaptureEnd?()
  }

  private func finishCapture() {
    isCapturing = false
    capturedModifierFlags = []
    capturedModifierSides = []
    needsDisplay = true
  }

  private func sides(in flags: NSEvent.ModifierFlags) -> ShortcutModifierSides? {
    guard distinguishModifierSides else { return nil }
    let value = ShortcutModifierSides(rawValue: UInt64(flags.rawValue))
      .intersection(ShortcutModifierSides.mask(for: UInt64(flags.rawValue)))
    return value.isEmpty ? nil : value
  }

  private func commit(_ definition: ShortcutDefinition) {
    finishCapture()
    displayName = definition.displayName
    onCapture?(definition)
    onCaptureEnd?()
    window?.makeFirstResponder(nil)
    needsDisplay = true
  }
}

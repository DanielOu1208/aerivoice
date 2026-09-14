import AppKit

enum ShortcutActivationMode: String, CaseIterable, Equatable, Identifiable, Sendable {
  case hybrid
  case toggle
  case hold

  var id: Self { self }

  var title: String {
    switch self {
    case .toggle: "Toggle"
    case .hybrid: "Hybrid"
    case .hold: "Hold"
    }
  }

  var instructions: String {
    switch self {
    case .toggle:
      "Press the shortcut once to start dictation and again to finish."
    case .hold:
      "Hold the shortcut to dictate and release to finish."
    case .hybrid:
      "Tap once to start and again to finish, or hold the shortcut and release to finish."
    }
  }
}

/// Device-dependent masks from IOKit/hidsystem/IOLLEvent.h. Aggregate flags alone
/// cannot distinguish releasing one side while the other side remains held.
struct ShortcutModifierSides: OptionSet, Codable, Equatable, Sendable {
  let rawValue: UInt64

  static let leftCommand = Self(rawValue: 0x08)
  static let rightCommand = Self(rawValue: 0x10)
  static let leftOption = Self(rawValue: 0x20)
  static let rightOption = Self(rawValue: 0x40)
  static let command: Self = [.leftCommand, .rightCommand]
  static let option: Self = [.leftOption, .rightOption]
  static let all: Self = [.command, .option]

  static func mask(for modifiers: UInt64) -> Self {
    var result: Self = []
    if modifiers & CGEventFlags.maskCommand.rawValue != 0 { result.formUnion(.command) }
    if modifiers & CGEventFlags.maskAlternate.rawValue != 0 { result.formUnion(.option) }
    return result
  }
}

struct ShortcutDefinition: Codable, Equatable, Sendable {
  let keyCode: UInt16
  let modifiers: UInt
  let displayName: String
  let isModifierOnly: Bool
  let modifierSides: ShortcutModifierSides?

  init(
    keyCode: UInt16, modifiers: UInt, displayName: String, isModifierOnly: Bool = false,
    modifierSides: ShortcutModifierSides? = nil
  ) {
    self.keyCode = keyCode
    self.modifiers = modifiers
    self.displayName = displayName
    self.isModifierOnly = isModifierOnly
    self.modifierSides = modifierSides
  }

  private enum CodingKeys: String, CodingKey {
    case keyCode, modifiers, displayName, isModifierOnly, modifierSides
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    keyCode = try container.decode(UInt16.self, forKey: .keyCode)
    modifiers = try container.decode(UInt.self, forKey: .modifiers)
    displayName = try container.decode(String.self, forKey: .displayName)
    isModifierOnly = try container.decodeIfPresent(Bool.self, forKey: .isModifierOnly) ?? false
    modifierSides = try container.decodeIfPresent(
      ShortcutModifierSides.self, forKey: .modifierSides)
  }

  var distinguishesModifierSides: Bool { modifierSides?.isEmpty == false }

  func removingModifierSideDistinction() -> Self {
    Self(
      keyCode: keyCode, modifiers: modifiers,
      displayName: displayName.replacingOccurrences(of: "L⌘", with: "⌘")
        .replacingOccurrences(of: "R⌘", with: "⌘")
        .replacingOccurrences(of: "L⌥", with: "⌥")
        .replacingOccurrences(of: "R⌥", with: "⌥")
        .replacingOccurrences(of: "⌘⌘", with: "⌘")
        .replacingOccurrences(of: "⌥⌥", with: "⌥"),
      isModifierOnly: isModifierOnly)
  }

  static let relevantFlags: CGEventFlags = [
    .maskCommand, .maskControl, .maskAlternate, .maskShift, .maskSecondaryFn,
  ]

  var requiredModifierBits: UInt64 {
    UInt64(modifiers) | (modifierSides?.rawValue ?? 0)
  }

  func modifierBits(in flags: CGEventFlags) -> UInt64 {
    let aggregate = flags.intersection(Self.relevantFlags).rawValue
    guard distinguishesModifierSides else { return aggregate }
    return aggregate
      | (flags.rawValue & ShortcutModifierSides.mask(for: UInt64(modifiers)).rawValue)
  }

  func matchesModifiers(_ flags: CGEventFlags) -> Bool {
    modifierBits(in: flags) == requiredModifierBits
  }

  var cgFlags: CGEventFlags { CGEventFlags(rawValue: UInt64(modifiers)) }
}

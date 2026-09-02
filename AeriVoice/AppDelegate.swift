import AppKit
import Combine
import SwiftUI
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate,
  UNUserNotificationCenterDelegate
{
  let model = AppModel()
  private var statusItem: NSStatusItem?
  private var settingsWindow: NSWindow?
  private var cancellables = Set<AnyCancellable>()

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)
    NSApp.mainMenu = Self.makeMainMenu()
    configureMenu()
    configureNotifications()
    observeLifecycle()
    if !model.setupComplete {
      openSettings()
    }
  }

  func applicationWillTerminate(_ notification: Notification) {
    model.coordinator.cancel()
    model.benchmarkRecorder.flushBeforeTermination()
  }

  private func configureMenu() {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    item.button?.image = NSImage(
      systemSymbolName: "waveform", accessibilityDescription: "AeriVoice")
    statusItem = item
    rebuildMenu()
    model.coordinator.$phase.sink { [weak self] _ in self?.rebuildMenu() }.store(in: &cancellables)
  }

  private func rebuildMenu() {
    let menu = NSMenu()
    let phase = model.coordinator.phase
    let title: String
    let action: Selector
    switch phase {
    case .starting, .recording:
      title = "Stop Dictation"
      action = #selector(toggle)
    case .processing, .cleaning, .inserting:
      title = "Cancel"
      action = #selector(cancel)
    default:
      title = "Start Dictation"
      action = #selector(toggle)
    }
    menu.addItem(withTitle: title, action: action, keyEquivalent: "")
    menu.addItem(.separator())
    menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
    menu.addItem(.separator())
    menu.addItem(
      withTitle: "Quit AeriVoice", action: #selector(quit), keyEquivalent: "q")
    for item in menu.items { item.target = self }
    statusItem?.menu = menu
    statusItem?.button?.image = NSImage(
      systemSymbolName: phase == .recording ? "waveform.circle.fill" : "waveform",
      accessibilityDescription: "AeriVoice")
  }

  private func configureNotifications() {
    let center = UNUserNotificationCenter.current()
    center.delegate = self
    let action = UNNotificationAction(identifier: "OPEN_SETTINGS_ACTION", title: "Open Settings")
    center.setNotificationCategories([
      UNNotificationCategory(identifier: "OPEN_SETTINGS", actions: [action], intentIdentifiers: [])
    ])
  }

  private func observeLifecycle() {
    let workspace = NSWorkspace.shared.notificationCenter
    workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) {
      [weak self] _ in Task { @MainActor in self?.model.coordinator.cancel() }
    }
    DistributedNotificationCenter.default().addObserver(
      forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: .main
    ) { [weak self] _ in Task { @MainActor in self?.model.coordinator.cancel() } }
  }

  @objc private func toggle() { model.coordinator.toggle() }
  @objc private func cancel() { model.coordinator.cancel() }
  @objc private func quit() { NSApp.terminate(nil) }

  @objc private func openSettings() {
    if model.preferences.onboardingComplete, !model.readinessComplete {
      model.settingsDestinationRequest = SettingsDestination.recommended(for: model)
    }
    setSettingsWindowVisible(true)
    let window: NSWindow
    if let settingsWindow {
      window = settingsWindow
    } else {
      window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 780, height: 640),
        styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered,
        defer: false)
      window.title = "AeriVoice Settings"
      window.contentMinSize = NSSize(width: 700, height: 560)
      window.isReleasedWhenClosed = false
      window.delegate = self
      settingsWindow = window
      window.contentView = NSHostingView(
        rootView: SettingsRootView(model: model) { [weak window] in
          window?.close()
        })
      window.center()
    }
    NSApp.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)
  }

  func windowWillClose(_ notification: Notification) {
    guard let window = notification.object as? NSWindow, window === settingsWindow else { return }
    setSettingsWindowVisible(false)
  }

  private func setSettingsWindowVisible(_ isVisible: Bool) {
    NSApp.setActivationPolicy(Self.activationPolicy(settingsWindowVisible: isVisible))
  }

  static func activationPolicy(settingsWindowVisible: Bool) -> NSApplication.ActivationPolicy {
    settingsWindowVisible ? .regular : .accessory
  }

  static func makeMainMenu() -> NSMenu {
    let mainMenu = NSMenu()

    let applicationMenuItem = NSMenuItem(title: "AeriVoice", action: nil, keyEquivalent: "")
    let applicationMenu = NSMenu(title: "AeriVoice")
    applicationMenu.addItem(
      withTitle: "About AeriVoice",
      action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
    applicationMenu.addItem(.separator())
    applicationMenu.addItem(
      withTitle: "Hide AeriVoice", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
    let hideOthers = applicationMenu.addItem(
      withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)),
      keyEquivalent: "h")
    hideOthers.keyEquivalentModifierMask = [.command, .option]
    applicationMenu.addItem(
      withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)),
      keyEquivalent: "")
    applicationMenu.addItem(.separator())
    applicationMenu.addItem(
      withTitle: "Quit AeriVoice", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    mainMenu.addItem(applicationMenuItem)
    mainMenu.setSubmenu(applicationMenu, for: applicationMenuItem)

    let editMenuItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
    let editMenu = NSMenu(title: "Edit")
    editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
    let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
    redo.keyEquivalentModifierMask = [.command, .shift]
    editMenu.addItem(.separator())
    editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    editMenu.addItem(
      withTitle: "Select All", action: #selector(NSStandardKeyBindingResponding.selectAll(_:)),
      keyEquivalent: "a")
    mainMenu.addItem(editMenuItem)
    mainMenu.setSubmenu(editMenu, for: editMenuItem)

    return mainMenu
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
  ) async {
    if response.actionIdentifier == "OPEN_SETTINGS_ACTION" {
      await MainActor.run { self.openSettings() }
    }
  }
}

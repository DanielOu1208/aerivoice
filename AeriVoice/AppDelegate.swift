import AppKit
import Combine
import SwiftUI
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
  let model = AppModel()
  private var statusItem: NSStatusItem?
  private var settingsWindow: NSWindow?
  private var cancellables = Set<AnyCancellable>()

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)
    configureMenu()
    configureNotifications()
    observeLifecycle()
    if !model.setupComplete {
      openSettings()
      Task { await model.requestMicrophonePermissionIfNeeded() }
    }
  }

  func applicationWillTerminate(_ notification: Notification) {
    model.coordinator.cancel()
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
    let window: NSWindow
    if let settingsWindow {
      window = settingsWindow
    } else {
      window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 540, height: 650),
        styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered,
        defer: false)
      window.title = "AeriVoice Settings"
      window.contentMinSize = NSSize(width: 500, height: 560)
      window.isReleasedWhenClosed = false
      window.contentView = NSHostingView(rootView: SettingsView(model: model))
      window.center()
      settingsWindow = window
    }
    NSApp.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
  ) async {
    if response.actionIdentifier == "OPEN_SETTINGS_ACTION" {
      await MainActor.run { self.openSettings() }
    }
  }
}

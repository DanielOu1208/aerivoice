import AVFoundation
import AppKit
import Combine
import SwiftUI
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate,
  UNUserNotificationCenterDelegate
{
  let model: AppModel
  private var statusItem: NSStatusItem?
  private var settingsWindow: NSWindow?
  private var settingsShowsOnboarding = false
  private var onboardingRequested = ProcessInfo.processInfo.arguments.contains("--show-onboarding")
  private var cancellables = Set<AnyCancellable>()

  init(launchStartedMS: Double = DiagnosticsClock.uptimeMS()) {
    model = AppModel(launchStartedMS: launchStartedMS)
    super.init()
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)
    NSApp.mainMenu = Self.makeMainMenu()
    configureMenu()
    model.runtimeDiagnostics.menuConfigured()
    configureNotifications()
    observeLifecycle()
    model.refreshTranscriptionSessionEligibility()
    model.coordinator.prepareForLaunch(
      microphoneAuthorized: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized)
    model.prewarmTranscription()
    if onboardingRequested {
      openSettings()
    } else if model.preferences.onboardingComplete, model.preferences.effectiveTranscriptionProvider == .local {
      Task { @MainActor [weak self] in
        guard let self else { return }
        await model.localModel.waitForPreparation()
        await model.appleSpeech.waitForPreparation()
        if !model.setupComplete { openSettings() }
      }
    } else if !model.setupComplete {
      openSettings()
    }
    model.runtimeDiagnostics.finishInitialization()
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    model.stopTranscriptionPreparation()
    model.coordinator.cancel()
    Task { @MainActor in
      await model.usageStats.finishPendingOperationsForTermination()
      sender.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
  }

  func applicationWillTerminate(_ notification: Notification) {
    model.stopTranscriptionPreparation()
    model.coordinator.cancel()
    model.runtimeDiagnostics.terminate()
    model.benchmarkRecorder.flushBeforeTermination()
  }

  private func configureMenu() {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    statusItem = item
    rebuildMenu()
    model.objectWillChange.receive(on: RunLoop.main)
      .sink { [weak self] _ in self?.rebuildMenu() }.store(in: &cancellables)
    model.preferences.objectWillChange.receive(on: RunLoop.main)
      .sink { [weak self] _ in self?.rebuildMenu() }.store(in: &cancellables)
  }

  private func rebuildMenu() {
    let menu = NSMenu()
    menu.autoenablesItems = false
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
    let dictationItem = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
    dictationItem.isEnabled = !model.changingOfflineMode
    let offlineItem = menu.addItem(withTitle: "Offline mode", action: #selector(toggleOfflineMode), keyEquivalent: "")
    offlineItem.state = model.preferences.offlineMode && !model.changingOfflineMode ? .on : .off
    offlineItem.isEnabled = model.canChangeOfflineMode
    offlineItem.toolTip = model.offlineModeExplanation
    if !model.selectedLocalAssetsInstalled {
      let setupItem = menu.addItem(withTitle: "Set up local model…", action: #selector(openLocalSetup), keyEquivalent: "")
      setupItem.toolTip = "Requires local model setup"
    }
    menu.addItem(.separator())
    menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
    menu.addItem(.separator())
    menu.addItem(
      withTitle: "Quit AeriVoice", action: #selector(quit), keyEquivalent: "q")
    for item in menu.items { item.target = self }
    statusItem?.menu = menu
    if let source = NSImage(named: "MenuBarIcon") {
      statusItem?.button?.image = MenuBarIconRenderer.image(
        from: source, recording: phase == .recording)
    }
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
      [weak self] _ in
      Task { @MainActor in
        self?.model.transcriptionWillSleep()
        self?.model.coordinator.cancel()
        self?.model.runtimeDiagnostics.willSleep()
      }
    }
    workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) {
      [weak self] _ in
      Task { @MainActor in
        guard let self else { return }
        self.model.runtimeDiagnostics.didWake()
        self.model.transcriptionDidWake()
      }
    }
    DistributedNotificationCenter.default().addObserver(
      forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: .main
    ) { [weak self] _ in
      Task { @MainActor in
        self?.model.transcriptionLockChanged(true)
        self?.model.coordinator.cancel()
      }
    }
    DistributedNotificationCenter.default().addObserver(
      forName: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main
    ) { [weak self] _ in Task { @MainActor in self?.model.refreshTranscriptionSessionEligibility() } }
    workspace.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) {
      [weak self] _ in Task { @MainActor in
        self?.model.transcriptionLockChanged(true)
        self?.model.coordinator.cancel()
      }
    }
    workspace.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main) {
      [weak self] _ in Task { @MainActor in self?.model.refreshTranscriptionSessionEligibility() }
    }
  }

  @objc private func toggle() {
    guard !model.changingOfflineMode else { return }
    model.coordinator.toggle()
  }
  @objc private func toggleOfflineMode() { model.setOfflineMode(!model.preferences.offlineMode) }
  @objc private func openLocalSetup() {
    model.showLocalSetup()
    openSettings()
    model.settingsDestinationRequest = .providers
  }
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
        contentRect: NSRect(x: 0, y: 0, width: 780, height: 720),
        styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
        backing: .buffered,
        defer: false)
      window.title = "AeriVoice Settings"
      window.titleVisibility = .hidden
      window.titlebarAppearsTransparent = false
      window.titlebarSeparatorStyle = .none
      window.contentMinSize = NSSize(width: 780, height: 720)
      window.isReleasedWhenClosed = false
      window.delegate = self
      settingsWindow = window
      window.center()
    }
    let needsOnboarding = onboardingRequested || !model.preferences.onboardingComplete
    if window.contentViewController == nil || settingsShowsOnboarding != needsOnboarding {
      settingsShowsOnboarding = needsOnboarding
      if needsOnboarding {
        window.toolbar = nil
        window.contentViewController = NSHostingController(
          rootView: OnboardingView(model: model, startAtBeginning: onboardingRequested) { [weak self, weak window] in
            self?.onboardingRequested = false
            window?.close()
          })
      } else {
        let navigation = SettingsNavigation(model: model)
        let controller = SettingsSplitViewController(
          sidebar: SettingsSidebar(model: model, navigation: navigation),
          detail: SettingsDetail(model: model, navigation: navigation),
          titleView: NSHostingView(rootView: SettingsToolbarTitle(navigation: navigation)))
        window.contentViewController = controller
        window.toolbar = controller.makeToolbar()
        window.toolbarStyle = .unified
      }
    }
    NSApp.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)
  }

  func windowWillClose(_ notification: Notification) {
    guard let window = notification.object as? NSWindow, window === settingsWindow else { return }
    for kind in CredentialKind.allCases { model.cancelCredentialValidation(kind) }
    model.settingsWindowWillClose.send()
    if let sheet = window.attachedSheet { window.endSheet(sheet) }
    setSettingsWindowVisible(false)
  }

  private func setSettingsWindowVisible(_ isVisible: Bool) {
    model.runtimeDiagnostics.setSettingsVisible(isVisible)
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
      withTitle: "Quit AeriVoice", action: #selector(NSApplication.terminate(_:)),
      keyEquivalent: "q")
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

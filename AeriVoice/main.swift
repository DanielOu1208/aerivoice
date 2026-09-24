import AppKit

#if AERIVOICE_UPDATER_QA
  precondition(Bundle.main.bundleIdentifier == "com.danielou.AeriVoice.UpdaterQA")
  // QA has its own defaults, credentials, stats, diagnostics and model directory.
  // It can exercise the updater without onboarding or cloud credentials.
  UserDefaults.standard.register(defaults: [
    "onboardingComplete": true,
    "launchAtLogin": false,
    "transcriptionProvider": "local",
    "localTranscriptionModel": "apple",
    "latencyLogging": false,
  ])
#endif

let launchStartedMS = DiagnosticsClock.uptimeMS()
let application = NSApplication.shared
let isRunningUnitTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
let appDelegate = isRunningUnitTests ? nil : AppDelegate(launchStartedMS: launchStartedMS)
application.delegate = appDelegate
application.run()

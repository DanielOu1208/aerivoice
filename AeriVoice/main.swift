import AppKit

let launchStartedMS = DiagnosticsClock.uptimeMS()
let application = NSApplication.shared
let isRunningUnitTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
let appDelegate = isRunningUnitTests ? nil : AppDelegate(launchStartedMS: launchStartedMS)
application.delegate = appDelegate
application.run()

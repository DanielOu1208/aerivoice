import AppKit

let application = NSApplication.shared
let isRunningUnitTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
let appDelegate = isRunningUnitTests ? nil : AppDelegate()
application.delegate = appDelegate
application.run()

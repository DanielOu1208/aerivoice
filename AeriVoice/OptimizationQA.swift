#if DEBUG
import AppKit

/// Explicit, synthetic candidate checks; never initializes the app model,
/// credentials, microphone, user preferences, or provider clients.
@MainActor
enum OptimizationQA {
  static var requested: Bool {
    ProcessInfo.processInfo.environment["AERIVOICE_OPTIMIZATION_QA"] != nil
  }

  static func run() async {
    let environment = ProcessInfo.processInfo.environment
    guard let output = environment["AERIVOICE_QA_OUTPUT"] else {
      NSApplication.shared.terminate(nil)
      return
    }
    do {
      let data: Data
      switch environment["AERIVOICE_OPTIMIZATION_QA"] {
      case "notch":
        data = try await NotchPresenter.runSyntheticBenchmark()
      case "paste":
        // Gives the native tester time to focus a disposable destination field.
        try await Task.sleep(for: .seconds(5))
        var outcomes: [String] = []
        let service = TextInsertionService(
          makeRestorationReport: { { outcomes.append($0.rawValue) } })
        let target = await service.captureTarget().value
        let result = await service.insert("AeriVoice QA café 中文 👋.", into: target)
        await service.finishPendingRestoration()
        data = try JSONSerialization.data(withJSONObject: [
          "insertion": String(describing: result), "restoration": outcomes,
          "readAware": environment["AERIVOICE_READ_AWARE_CLIPBOARD"] == "1",
        ], options: [.prettyPrinted, .sortedKeys])
      default:
        throw CocoaError(.featureUnsupported)
      }
      try data.write(to: URL(fileURLWithPath: output), options: .atomic)
    } catch {
      // No raw errors or data from a target application go into this report.
      try? Data("{\"qaFailed\":true}".utf8).write(to: URL(fileURLWithPath: output))
    }
    NSApplication.shared.terminate(nil)
  }
}
#endif

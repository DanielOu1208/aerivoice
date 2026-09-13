import Foundation

@main
struct HarnessMain {
  @MainActor
  static func main() async {
    let events = EvalEvents()
    do {
      let arguments = CommandLine.arguments
      if arguments.count == 2, arguments[1] == "capabilities" {
        let object: [String: Any] = [
          "protocol_version": 1,
          "transcription_providers": TranscriptionProvider.allCases.map {
            ["id": $0.rawValue, "model": $0.modelID, "credential_key": $0.credentialKind.rawValue]
          },
          "cleanup_models": CleanupModel.allCases.map {
            ["id": $0.rawValue, "provider": $0.provider.rawValue,
             "credential_key": $0.provider.credentialKind.rawValue,
             "reasoning_efforts": $0.supportedReasoningEfforts.map(\.rawValue),
             "default_reasoning": $0.defaultReasoningEffort.rawValue] as [String: Any]
          },
          "kinds": ["pipeline", "transcription", "cleanup", "conversion", "stability"],
          "modes": ["live", "controlled"],
        ]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        FileHandle.standardOutput.write(data + Data([10]))
        return
      }
      guard arguments.count == 3, arguments[1] == "run" else { throw EvalError.invalidScenario }
      let decoder = JSONDecoder()
      decoder.keyDecodingStrategy = .convertFromSnakeCase
      let scenario = try decoder.decode(EvalScenario.self, from: Data(contentsOf: URL(fileURLWithPath: arguments[2])))
      try scenario.validate()
      let credentials = try EvalCredentials.read(controlled: !scenario.live || scenario.kind == "conversion")
      try await EvalRunner(scenario: scenario, events: events, credentials: credentials).run()
    } catch {
      events.emit("run_failed", ["category": evalFailure(error)])
      exit(1)
    }
  }
}

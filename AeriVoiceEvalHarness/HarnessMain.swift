import Foundation

@main
struct HarnessMain {
  @MainActor
  static func main() async {
    let events = EvalEvents()
    do {
      let arguments = CommandLine.arguments
      if arguments.count == 2, arguments[1] == "download-local-model" {
        let assets = LocalModelAssets()
        let directory = try await assets.download { progress in
          events.emit("model_download", ["progress": progress])
        }
        events.emit("model_installed", ["path": directory.path])
        return
      }
      if arguments.count == 2, arguments[1] == "capabilities" {
        let object: [String: Any] = [
          "protocol_version": 1,
          "transcription_providers": TranscriptionProvider.allCases.map {
            var entry: [String: Any] = ["id": $0.rawValue, "model": $0.modelID,
              "requires_credentials": $0.credentialKind != nil]
            if let kind = $0.credentialKind { entry["credential_key"] = kind.rawValue }
            if $0 == .local {
              entry["local_models"] = ["nemotron", "apple"]
              entry["apple_locale_selection"] = true
            }
            return entry
          },
          "cleanup_models": CleanupModel.allCases.map {
            ["id": $0.rawValue, "provider": $0.provider.rawValue,
             "credential_key": $0.provider.credentialKind.rawValue,
             "reasoning_efforts": $0.supportedReasoningEfforts.map(\.rawValue),
             "default_reasoning": $0.defaultReasoningEffort.rawValue] as [String: Any]
          },
          "kinds": ["pipeline", "transcription", "cleanup", "conversion", "stability"],
          "modes": ["live", "controlled"],
          "optional_scenario_fields": [
            "cleanup_custom_instructions": ["type": "string",
              "max_characters": CleanupInstructions.maxCustomInstructionCharacters],
            "cleanup_prompt_override": ["type": "string", "kinds": ["cleanup"],
              "max_characters": EvalScenario.maxPromptOverrideCharacters,
              "incompatible_with": ["nonempty cleanup_custom_instructions"]],
          ],
          "prompt_character_count": "unicode_scalars",
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
      let credentials: EvalCredentials
      if scenario.live, scenario.provider == .local, scenario.kind == "transcription" || scenario.offlineMode == true {
        credentials = EvalCredentials(values: [:], controlled: false)
      } else {
        credentials = try EvalCredentials.read(controlled: !scenario.live || scenario.kind == "conversion")
      }
      try await EvalRunner(scenario: scenario, events: events, credentials: credentials).run()
    } catch {
      events.emit("run_failed", ["category": evalFailure(error)])
      exit(1)
    }
  }
}

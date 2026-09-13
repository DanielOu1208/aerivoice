import Combine
import Foundation

@MainActor
final class EvalRunner {
  let scenario: EvalScenario
  let events: EvalEvents
  let credentials: EvalCredentials
  private let resources: EvalResources
  private var deadline = 0.0
  private var interrupted = false
  private var signals: [DispatchSourceSignal] = []

  init(scenario: EvalScenario, events: EvalEvents, credentials: EvalCredentials) {
    self.scenario = scenario; self.events = events; self.credentials = credentials
    resources = EvalResources(events: events)
  }

  func run() async throws {
    deadline = events.elapsedMS + scenario.timeout * 1_000
    for signalNumber in [SIGINT, SIGTERM] {
      signal(signalNumber, SIG_IGN)
      let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
      source.setEventHandler { [weak self] in
        MainActor.assumeIsolated {
          self?.interrupted = true
          self?.events.emit("interruption_requested")
        }
      }
      signals.append(source)
      source.resume()
    }
    defer { resources.stop(); signals.forEach { $0.cancel() } }
    resources.start()
    events.emit("run_started", [
      "id": scenario.id ?? "evaluation", "kind": scenario.kind, "mode": scenario.mode,
      "pid": getpid(), "environment": EvalEvents.object(BenchmarkEnvironment.live),
      "measurement_boundary": "production_pipeline_harness", "resource_sampling_interval_ms": 100,
      "instrumentation_cpu_included": true, "audio_hardware": false, "desktop_insertion": false,
      "cleanup_bypassed": scenario.kind == "transcription",
    ])
    if scenario.kind == "cleanup" { try await runCleanup(); return }
    guard let path = scenario.audioPath else { throw EvalError.invalidAudio }
    let fixture = try EvalAudioFixture(path: path, rate: scenario.fixtureRate,
                                      channels: scenario.fixtureChannels, chunkFrames: scenario.fixtureChunkFrames)
    events.emit("fixture_loaded", ["sha256": fixture.hash, "frames": fixture.frames, "sample_rate": fixture.rate,
                                    "channels": fixture.channels, "duration_ms": fixture.durationMS,
                                    "pcm_bytes": fixture.pcmBytes, "predecoded": true])
    if scenario.kind == "conversion" { try await runConversion(fixture); return }
    try await runSessions(fixture)
  }

  private func makeCleaner() -> EvalCleaner {
    if scenario.kind == "transcription" { return EvalCleaner(client: EvalIdentityCleaner(), events: events) }
    let configuration = URLSessionConfiguration.ephemeral
    if !scenario.live {
      configuration.protocolClasses = [EvalHTTPProtocol.self]
      EvalHTTPProtocol.configure(script: scenario.script,
                                 output: scenario.script.cleanupText ?? scenario.scriptedTranscript)
    }
    let session = URLSession(configuration: configuration)
    return EvalCleaner(client: CleanupClientRouter(
      openRouter: OpenRouterCleanupClient(session: session), groq: GroqCleanupClient(session: session),
      cerebras: CerebrasCleanupClient(session: session)), events: events)
  }

  private func runSessions(_ fixture: EvalAudioFixture) async throws {
    let engine = EvalCaptureEngine(fixture: fixture, events: events)
    let route = AudioInputRoute(deviceID: 1, sampleRate: fixture.rate, channels: UInt32(fixture.channels))
    let audio = AudioCaptureService(makeEngine: { engine }, currentRoute: { route })
    let soniox: SonioxRealtimeClient
    let meta: MetaRealtimeClient
    if scenario.live { soniox = SonioxRealtimeClient(); meta = MetaRealtimeClient() }
    else {
      let script = scenario.script
      let text = scenario.scriptedTranscript
      soniox = SonioxRealtimeClient(makeTransport: { _ in EvalScriptedSocket(provider: .soniox, script: script, text: text) })
      meta = MetaRealtimeClient(makeTransport: { _ in EvalScriptedSocket(provider: .meta, script: script, text: text) })
    }
    let transcriber = EvalTranscriber(client: RealtimeTranscriptionRouter(soniox: soniox, meta: meta), events: events)
    let cleaner = makeCleaner()
    let benchmark = EvalBenchmark(events: events)
    let lifecycle = EvalLifecycle(events: events)
    let receiver = EvalReceiver(events: events)
    let suiteName = "com.danielou.AeriVoiceEvalHarness." + UUID().uuidString
    guard let defaults = UserDefaults(suiteName: suiteName) else { throw EvalError.internalFailure }
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let preferences = AppPreferences(defaults: defaults, loginItemManager: EvalLoginItems())
    preferences.onTranscriptionProviderChange = {}
    preferences.transcriptionProvider = scenario.provider
    preferences.cleanupProvider = scenario.model.provider
    preferences.cleanupModel = scenario.model
    preferences.cleanupReasoningEffort = scenario.configuration.reasoningEffort
    preferences.cleanupMode = scenario.cleaningMode
    preferences.vocabulary = (scenario.vocabulary ?? []).joined(separator: "\n")
    preferences.soundCues = scenario.soundCues ?? true
    preferences.muteOutput = true
    preferences.onboardingComplete = true
    preferences.latencyLogging = false
    var values = credentials.values
    if scenario.kind == "transcription" { values[scenario.model.provider.credentialKind.rawValue] = "eval-stage-bypass" }
    let stageCredentials = EvalCredentials(values: values, controlled: !scenario.live)
    let coordinator = DictationCoordinator(
      preferences: preferences, credentials: stageCredentials, audio: audio, transcriber: transcriber,
      cleaner: cleaner, muter: EvalMuter(), inserter: receiver, notch: EvalNotch(), benchmark: benchmark,
      readiness: EvalReadiness(), cuePlayer: EvalCues(), lifecycleObserver: lifecycle,
      notifications: EvalNotifications(events: events))
    let observation = coordinator.$phase.removeDuplicates().sink { [events] phase in
      events.emit("phase", ["phase": evalPhase(phase)])
    }
    defer { observation.cancel(); audio.stop() }
    if scenario.prepared == true {
      events.emit("preparation_started")
      coordinator.prepareForLaunch(microphoneAuthorized: true)
      try await waitUntil { !lifecycle.work.values.contains("launchPreparation") }
      events.emit("preparation_finished", ["physical_engine_prepare_measured": false])
    }
    for index in 1...scenario.count {
      try checkDeadline()
      events.setSession(index)
      transcriber.reset(); receiver.reset(); engine.resetForSession()
      let start = events.elapsedMS
      events.emit("session_started", ["index": index])
      resources.sample("session_baseline")
      coordinator.toggle()
      var didStop = false
      do {
        try await waitUntil {
          if let cancelMS = self.scenario.cancelAfterMs, self.events.elapsedMS - start >= cancelMS,
            benchmark.terminal == nil { coordinator.cancel() }
          if engine.finished, !didStop, benchmark.terminal == nil {
            didStop = true
            coordinator.toggle()
          }
          return benchmark.terminal != nil
        }
      } catch {
        coordinator.cancel()
        events.emit("result", ["status": "cancelled", "category": evalFailure(error), "raw_text": transcriber.rawText])
        throw error
      }
      let result = benchmark.terminal
      let status: String
      switch result {
      case .pasteSent, .inserted: status = benchmark.fallback ? "fallback" : "success"
      case .cancelled: status = "cancelled"
      default: status = "failed"
      }
      var payload: [String: Any] = [
        "status": status, "raw_text": transcriber.rawText, "durations_ms": benchmark.durations,
        "milestones_ms": benchmark.milestones, "captured_bytes": benchmark.capturedBytes,
        "sent_bytes": benchmark.sentBytes, "max_buffered_bytes": benchmark.maxBufferedBytes,
        "audio_feed": engine.feedSummary, "failure": benchmark.failure,
        "cleanup_bypassed": scenario.kind == "transcription",
      ]
      payload["output_text"] = receiver.output
      events.emit("result", payload)
      resources.sample("result")
      let until = events.elapsedMS + scenario.observationMS
      try await waitUntil { self.events.elapsedMS >= until }
      resources.sample("observation_end")
      events.emit("observation_finished", [
        "coordinator_phase": evalPhase(coordinator.phase),
        "coordinator_tasks": Array(lifecycle.work.values).sorted(),
        "transcriber_operations": transcriber.activeOperations,
        "cleanup_operations": cleaner.activeOperations,
        "soniox_retains_session": soniox.retainsSession,
        "observed_work_settled": lifecycle.work.isEmpty && transcriber.activeOperations == 0 && cleaner.activeOperations == 0,
        "settlement_scope": "coordinator_task_bodies_and_wrapped_provider_operations",
        "audio_callback_tasks_unobserved": true,
        "network_internal_tasks_unobserved": true,
      ])
      if index < scenario.count {
        let next = events.elapsedMS + (scenario.gapMs ?? 0)
        try await waitUntil { self.events.elapsedMS >= next }
      }
    }
    // Do not cancel reused clients to manufacture a lower retained-memory measurement.
    events.emit("run_finished", ["sessions": scenario.count, "process_exit_pending": true])
  }

  private func runCleanup() async throws {
    let cleaner = makeCleaner()
    guard let key = credentials.value(for: scenario.model.provider.credentialKind), !key.isEmpty,
      let text = scenario.transcript else { throw EvalError.missingCredential }
    for index in 1...scenario.count {
      try checkDeadline()
      events.setSession(index)
      events.emit("session_started", ["index": index])
      resources.sample("session_baseline")
      let start = events.elapsedMS
      let operation = EvalCleanupOperation()
      let task = Task {
        do {
          operation.result = .success(try await cleaner.clean(text, mode: scenario.cleaningMode,
                                                             configuration: scenario.configuration, apiKey: key))
        } catch { operation.result = .failure(error) }
      }
      var cancellation: String?
      while operation.result == nil {
        if interrupted { cancellation = "interrupted" }
        else if events.elapsedMS >= deadline { cancellation = "deadline" }
        else if let cancelMS = scenario.cancelAfterMs, events.elapsedMS - start >= cancelMS { cancellation = "cancelled" }
        if cancellation != nil {
          task.cancel()
          break
        }
        try await Task.sleep(for: .milliseconds(5))
      }
      await task.value
      do {
        if let cancellation {
          events.emit("result", ["status": "cancelled", "raw_text": text, "category": cancellation,
                                 "durations_ms": ["cleanupMS": events.elapsedMS - start]])
        } else {
          guard let outcome = operation.result else { throw EvalError.internalFailure }
          let result = try outcome.get()
          events.emit("result", ["status": "success", "raw_text": text, "output_text": result.text,
                                 "durations_ms": ["cleanupMS": events.elapsedMS - start]])
        }
      } catch {
        events.emit("result", ["status": "failed", "raw_text": text, "category": evalFailure(error)])
      }
      resources.sample("result")
      let next = events.elapsedMS + scenario.observationMS + (index < scenario.count ? scenario.gapMs ?? 0 : 0)
      try await waitUntil { self.events.elapsedMS >= next }
      resources.sample("observation_end")
      events.emit("observation_finished", ["cleanup_operations": cleaner.activeOperations])
    }
    events.emit("run_finished", ["sessions": scenario.count, "process_exit_pending": true])
  }

  private func runConversion(_ fixture: EvalAudioFixture) async throws {
    for index in 1...scenario.count {
      try checkDeadline()
      events.setSession(index)
      events.emit("session_started", ["index": index])
      resources.sample("session_baseline")
      let start = events.elapsedMS
      guard let converter = PCM16AudioConverter() else { throw EvalError.invalidAudio }
      var bytes = 0
      for buffer in fixture.buffers {
        try checkDeadline()
        guard let data = converter.convert(buffer) else { throw EvalError.invalidAudio }
        bytes += data.count
      }
      events.emit("result", ["status": "success", "converted_bytes": bytes,
                             "durations_ms": ["conversionMS": events.elapsedMS - start], "realtime_pacing": false])
      resources.sample("result")
      let next = events.elapsedMS + scenario.observationMS
      try await waitUntil { self.events.elapsedMS >= next }
      resources.sample("observation_end")
      events.emit("observation_finished")
    }
    events.emit("run_finished", ["sessions": scenario.count, "process_exit_pending": true])
  }

  private func checkDeadline() throws {
    if interrupted { throw EvalError.interrupted }
    if events.elapsedMS >= deadline { throw EvalError.deadline }
  }

  private func waitUntil(_ predicate: () -> Bool) async throws {
    while !predicate() { try checkDeadline(); try await Task.sleep(for: .milliseconds(5)) }
  }
}

@MainActor
private final class EvalCleanupOperation {
  var result: Result<CleanupTextResult, Error>?
}

import Foundation

struct DiagnosticSettings: Codable, Equatable, Sendable {
  let transcriptionProvider: String
  let cleanupProvider: String
  let cleanupModel: String
  let cleanupMode: String
  let reasoningEffort: String
  let soundCues: Bool
  let muteOutput: Bool
  let activationMode: String
  let onboardingComplete: Bool

  @MainActor init(_ preferences: AppPreferences) {
    transcriptionProvider = preferences.transcriptionProvider.rawValue
    cleanupProvider = preferences.cleanupProvider.rawValue
    cleanupModel = preferences.cleanupModel.rawValue
    cleanupMode = preferences.cleanupMode.rawValue
    reasoningEffort = preferences.cleanupReasoningEffort.rawValue
    soundCues = preferences.soundCues
    muteOutput = preferences.muteOutput
    activationMode = preferences.shortcutActivationMode.rawValue
    onboardingComplete = preferences.onboardingComplete
  }
}

struct InteractionDiagnosticContext: Codable, Equatable, Sendable {
  let launchID: UUID
  let activationIndex: Int
  let sinceLaunchMS: Double
  let sincePreviousInteractionMS: Double?
  let sinceWakeMS: Double?
  let settings: DiagnosticSettings
}

enum RuntimeActivity: String, Codable, Sendable {
  case launching, preparing, dictating, settling, settings, idle, sleeping
}

enum RuntimeEvent: String, Codable, Sendable {
  case initializationStarted, initializationFinished, menuConfigured
  case shortcutEnabled, shortcutUnavailable
  case preparationStarted, preparationFinished, preparationSkipped
  case networkWarmupStarted, networkWarmupFinished
  case interactionBegan, interactionFinished, phaseChanged, sessionCleanupFinished
  case settingsOpened, settingsClosed, settingsChanged, sleep, wake, termination
  case loggingEnabled, loggingDisabled, resourceSample, resourceUnavailable
}

enum DiagnosticPreparationResult: String, Codable, Sendable {
  case prepared, skipped, failed, cancelled, unknown
}

struct RuntimeDiagnosticRecord: Codable, Equatable, Sendable {
  let schemaVersion: Int
  let recordID: UUID
  let launchID: UUID
  let processID: Int32
  let recordedAt: Date
  let uptimeMS: Double
  let sinceLaunchMS: Double
  let event: RuntimeEvent
  let activity: RuntimeActivity
  let activityGeneration: UUID
  let interactionID: UUID?
  let environment: BenchmarkEnvironment
  let settings: DiagnosticSettings
  var result: DiagnosticPreparationResult?
  var resources: ProcessResourceSnapshot?
  var resourceInterval: ResourceInterval?
  var audioRoute: DiagnosticAudioRoute?
  let droppedResourceSamples: Int
  let droppedWrites: Int
}

@MainActor
final class RuntimeDiagnosticsRecorder {
  let launchID = UUID()
  let environment: BenchmarkEnvironment
  let writer: DiagnosticsWriteQueue
  private(set) var enabled: Bool
  private(set) var activity: RuntimeActivity = .launching
  private(set) var activityGeneration = UUID()
  private(set) var currentInteractionID: UUID?
  private let launchStartedMS: Double
  private let nowMS: () -> Double
  private let wallNow: () -> Date
  private let settings: () -> DiagnosticSettings
  private var lastSettings: DiagnosticSettings
  private let sampler: any ResourceSampling
  private let audioRoute: @Sendable () -> DiagnosticAudioRoute?
  private let signposts = PerformanceSignposts()
  private var timer: DispatchSourceTimer?
  private var sampleTask: Task<Void, Never>?
  private var sampleRequested = false
  private var sampleGeneration = UUID()
  private var previousResource: ProcessResourceSnapshot?
  private var droppedSamples = 0
  private var activationIndex = 0
  private var previousInteractionEndMS: Double?
  private var lastWakeMS: Double?
  private var initializationFinished = false
  private var sleeping = false
  private var settingsVisible = false
  private var phase = "idle"
  private var preparations: [UUID: Bool] = [:]
  private let scheduleTimer: Bool

  init(
    enabled: Bool, writer: DiagnosticsWriteQueue, launchStartedMS: Double,
    environment: BenchmarkEnvironment = .live,
    settings: @escaping () -> DiagnosticSettings,
    sampler: any ResourceSampling = ProcessResourceSampler(),
    audioRoute: @escaping @Sendable () -> DiagnosticAudioRoute? = DiagnosticAudioRoute.current,
    nowMS: @escaping () -> Double = DiagnosticsClock.uptimeMS,
    wallNow: @escaping () -> Date = Date.init,
    scheduleTimer: Bool = true
  ) {
    self.enabled = enabled
    self.writer = writer
    self.launchStartedMS = launchStartedMS
    self.environment = environment
    self.settings = settings
    self.lastSettings = settings()
    self.sampler = sampler
    self.audioRoute = audioRoute
    self.nowMS = nowMS
    self.wallNow = wallNow
    self.scheduleTimer = scheduleTimer
    signposts.setEnabled(enabled)
    if enabled {
      signposts.begin(.initialization)
      emit(.initializationStarted, timestampMS: launchStartedMS)
      requestResourceSample()
    }
  }

  deinit { timer?.cancel(); sampleTask?.cancel() }

  func setEnabled(_ value: Bool) {
    guard enabled != value else { return }
    // A final control marker lets an external observer stop trusting an old idle baseline.
    if !value { persist(makeRecord(.loggingDisabled), control: true) }
    enabled = value
    signposts.setEnabled(value)
    resetResourceBaseline()
    if value { emit(.loggingEnabled); requestResourceSample() }
    updateTimer()
  }

  func finishInitialization() {
    initializationFinished = true
    signposts.end(.initialization)
    updateActivity()
    emit(.initializationFinished)
    requestResourceSample()
  }

  func menuConfigured() { emit(.menuConfigured) }
  func shortcutAvailable(_ available: Bool) {
    emit(available ? .shortcutEnabled : .shortcutUnavailable)
  }

  func beginPreparation(network: Bool = false) -> UUID {
    let token = UUID()
    preparations[token] = network
    if enabled { signposts.beginPreparation(token, network: network) }
    updateActivity()
    emit(network ? .networkWarmupStarted : .preparationStarted)
    requestResourceSample()
    return token
  }

  func finishPreparation(_ token: UUID, result: DiagnosticPreparationResult) {
    guard let network = preparations.removeValue(forKey: token) else { return }
    signposts.endPreparation(token)
    updateActivity()
    emit(network ? .networkWarmupFinished : .preparationFinished, result: result)
    requestResourceSample()
  }

  func preparationSkipped() { emit(.preparationSkipped, result: .skipped) }

  func beginInteraction() -> (UUID, InteractionDiagnosticContext) {
    activationIndex += 1
    let id = UUID()
    currentInteractionID = id
    phase = "starting"
    updateActivity()
    let timestamp = nowMS()
    let context = InteractionDiagnosticContext(
      launchID: launchID, activationIndex: activationIndex,
      sinceLaunchMS: max(0, timestamp - launchStartedMS),
      sincePreviousInteractionMS: previousInteractionEndMS.map { max(0, timestamp - $0) },
      sinceWakeMS: lastWakeMS.map { max(0, timestamp - $0) }, settings: settings())
    emit(.interactionBegan)
    requestResourceSample()
    return (id, context)
  }

  func milestone(_ value: BenchmarkMilestone) {
    guard enabled else { return }
    signposts.milestone(value)
    switch value {
    case .audioEngineStartRequested, .captureStarted, .stopRequested,
      .sttFinalizeStarted, .sttFinalized, .cleanupStarted, .cleanupFinished,
      .insertionStarted, .insertionFinished:
      resetResourceBaseline()
      requestResourceSample()
    default: break
    }
  }

  func finishInteraction() {
    guard currentInteractionID != nil, phase != "settling", phase != "idle" else { return }
    previousInteractionEndMS = nowMS()
    phase = "settling"
    signposts.endInteraction()
    updateActivity()
    emit(.interactionFinished)
    requestResourceSample()
  }

  func phaseChanged(_ value: DictationPhase) {
    let next: String
    switch value {
    case .idle: next = "idle"
    case .starting: next = "starting"
    case .recording: next = "recording"
    case .processing: next = "processing"
    case .cleaning: next = "cleaning"
    case .inserting: next = "inserting"
    case .success, .error: next = "settling"
    }
    guard next != phase else { return }
    phase = next
    if next == "idle" { currentInteractionID = nil }
    resetResourceBaseline()
    updateActivity()
    emit(.phaseChanged)
    requestResourceSample()
  }

  func sessionCleanupFinished() { emit(.sessionCleanupFinished) }

  func setSettingsVisible(_ value: Bool) {
    guard settingsVisible != value else { return }
    settingsVisible = value
    updateActivity()
    emit(value ? .settingsOpened : .settingsClosed)
    requestResourceSample()
  }

  func settingsChanged() {
    let current = settings()
    guard current != lastSettings else { return }
    lastSettings = current
    resetResourceBaseline()
    emit(.settingsChanged)
    requestResourceSample()
  }

  func historyWillClear() { resetResourceBaseline() }

  func willSleep() {
    sleeping = true
    signposts.endAll()
    resetResourceBaseline()
    updateActivity()
    emit(.sleep)
  }

  func didWake() {
    sleeping = false
    lastWakeMS = nowMS()
    resetResourceBaseline()
    updateActivity()
    emit(.wake)
    requestResourceSample()
  }

  func terminate() {
    timer?.cancel()
    timer = nil
    signposts.endAll()
    emit(.termination)
    enabled = false
    sampleRequested = false
    sampleGeneration = UUID()
    sampleTask?.cancel()
  }

  private func updateActivity() {
    let next: RuntimeActivity
    if sleeping { next = .sleeping }
    else if !["idle", "settling"].contains(phase) { next = .dictating }
    else if !initializationFinished { next = .launching }
    else if !preparations.isEmpty { next = .preparing }
    else if phase == "settling" { next = .settling }
    else if settingsVisible { next = .settings }
    else { next = .idle }
    if next != activity {
      activity = next
      resetResourceBaseline()
    }
    updateTimer()
  }

  private func resetResourceBaseline() {
    activityGeneration = UUID()
    sampleGeneration = UUID()
    previousResource = nil
    sampleRequested = false
  }

  private func updateTimer() {
    guard scheduleTimer, enabled, activity == .idle else {
      timer?.cancel()
      timer = nil
      return
    }
    guard timer == nil else { return }
    let source = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
    source.schedule(deadline: .now() + 300, repeating: 300, leeway: .seconds(30))
    source.setEventHandler { [weak self] in
      Task { @MainActor [weak self] in
        guard let self, self.enabled, self.activity == .idle else { return }
        self.requestResourceSample()
      }
    }
    timer = source
    source.resume()
  }

  /// At most one sampler is running. Fast milestone bursts coalesce into one new request.
  func requestResourceSample() {
    guard enabled, !sleeping else { return }
    guard sampleTask == nil else {
      sampleRequested = true
      droppedSamples += 1
      return
    }
    let generation = sampleGeneration
    let sampler = sampler
    let audioRoute = audioRoute
    sampleTask = Task { [weak self] in
      guard let self else { return }
      // The main actor may have changed state before this task first runs.
      guard self.enabled, !self.sleeping, self.sampleGeneration == generation else {
        self.sampleTask = nil
        self.sampleAgainIfRequested()
        return
      }
      let result = await Task.detached(priority: .utility) {
        // Route lookup is deliberately before acquisition, so the sample timestamp stays meaningful.
        let route = audioRoute()
        return (sampler.sample(), route)
      }.value
      self.sampleTask = nil
      guard self.enabled, !self.sleeping else { return }
      if self.sampleGeneration == generation {
        var record = self.makeRecord(result.0 == nil ? .resourceUnavailable : .resourceSample)
        record.resources = result.0
        record.audioRoute = result.1
        if let previous = self.previousResource, let current = result.0 {
          record.resourceInterval = ResourceInterval(from: previous, to: current)
        }
        self.previousResource = result.0
        self.persist(record)
      } else { self.droppedSamples += 1 }
      self.sampleAgainIfRequested()
    }
  }

  private func sampleAgainIfRequested() {
    guard sampleRequested else { return }
    sampleRequested = false
    requestResourceSample()
  }

  func flushForTesting() async {
    while let sampleTask { await sampleTask.value }
    await writer.flush()
  }

  private func makeRecord(_ event: RuntimeEvent, timestampMS: Double? = nil) -> RuntimeDiagnosticRecord {
    let timestamp = timestampMS ?? nowMS()
    return RuntimeDiagnosticRecord(
      schemaVersion: 1, recordID: UUID(), launchID: launchID, processID: getpid(),
      recordedAt: wallNow().addingTimeInterval((timestamp - nowMS()) / 1_000), uptimeMS: timestamp,
      sinceLaunchMS: max(0, timestamp - launchStartedMS), event: event,
      activity: activity, activityGeneration: activityGeneration,
      interactionID: currentInteractionID, environment: environment, settings: settings(),
      droppedResourceSamples: droppedSamples, droppedWrites: writer.droppedWrites)
  }

  private func emit(
    _ event: RuntimeEvent, result: DiagnosticPreparationResult? = nil, timestampMS: Double? = nil
  ) {
    guard enabled else { return }
    var record = makeRecord(event, timestampMS: timestampMS)
    record.result = result
    persist(record)
  }

  private func persist(_ record: RuntimeDiagnosticRecord, control: Bool = false) {
    writer.enqueue(control: control) { store in
      let encoder = DiagnosticsJSON.encoder()
      try await store.appendRuntime(encoder.encode(record), now: record.recordedAt)
    }
  }
}

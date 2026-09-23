import AVFoundation
import AppKit

@MainActor
protocol DictationReadinessChecking: Sendable {
  func requestMicrophone() async -> Bool
  func accessibilityReady(prompt: Bool) -> Bool
}

struct SystemDictationReadiness: DictationReadinessChecking {
  func requestMicrophone() async -> Bool {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized: true
    case .notDetermined: await AVCaptureDevice.requestAccess(for: .audio)
    default: false
    }
  }

  func accessibilityReady(prompt: Bool) -> Bool {
    guard !AXIsProcessTrusted(), prompt else { return AXIsProcessTrusted() }
    _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    return false
  }
}

@MainActor
final class DictationCoordinator: ObservableObject {
  private struct ActiveCleanupSettings {
    let instructions: CleanupInstructions
    let configuration: CleanupConfiguration
  }

  @Published private(set) var phase: DictationPhase = .idle {
    didSet { runtimeDiagnostics?.phaseChanged(phase) }
  }

  private let preferences: AppPreferences
  private let credentials: CredentialReading
  private let audio: AudioCapturing
  private let transcriber: RealtimeTranscribing
  private let cleaner: CleaningText
  private let muter: OutputMuting
  private let inserter: TextInserting
  private let notch: NotchPresenting
  private let usageStats: UsageStatsRecording?
  private var usageSession: UsageSession?
  private var captureStartedAt: ContinuousClock.Instant?
  private var recordingSeconds: Double = 0
  private let benchmark: LatencyBenchmarkRecording
  private let readiness: DictationReadinessChecking
  private let cuePlayer: SoundCuePlaying
  private let runtimeDiagnostics: RuntimeDiagnosticsRecorder?
  private let lifecycleObserver: DictationLifecycleObserving?
  private let notifications: DictationNotificationPosting

  private var sessionID: DictationSessionID?
  private var activeTranscriptionConfiguration: TranscriptionConfiguration?
  private var activeCleanupSettings: ActiveCleanupSettings?
  private var skipsCleanup = false
  private var state = NotchState(phase: .idle)
  private var bufferedAudio: [Data] = []
  private var bufferedBytes = 0
  private var connected = false
  private var connectionTask: Task<Void, Never>?
  private var connectionTaskID: UUID?
  private var drainTask: Task<Void, Never>?
  private var limitTask: Task<Void, Never>?
  private var audioStopped = true
  private var audioStarting = false
  private var launchPreparationAttempted = false
  private var launchPreparationTask: Task<Void, Never>?
  private var lifecycleGeneration = UUID()
  private var startTask: Task<Void, Never>?
  private var stopTask: Task<Void, Never>?
  private var targetCaptureTask: Task<TextInsertionTarget?, Never>?
  private var stopTaskID: UUID?
  private var drainTaskID: UUID?
  var onSuccessfulSessionCompletion: (() -> Void)?

  var canCancel: Bool {
    switch phase {
    case .starting, .recording, .processing, .cleaning, .inserting: true
    default: false
    }
  }

  init(
    preferences: AppPreferences, credentials: CredentialReading,
    audio: AudioCapturing = AudioCaptureService(),
    transcriber: RealtimeTranscribing = RealtimeTranscriptionRouter(),
    cleaner: CleaningText = CleanupClientRouter(), muter: OutputMuting = OutputMuteController(),
    inserter: TextInserting? = nil, notch: NotchPresenting = NotchPresenter(),
    benchmark: LatencyBenchmarkRecording = LatencyBenchmarkRecorder(),
    usageStats: UsageStatsRecording? = nil,
    readiness: DictationReadinessChecking = SystemDictationReadiness(),
    cuePlayer: SoundCuePlaying = SoundCuePlayer(),
    runtimeDiagnostics: RuntimeDiagnosticsRecorder? = nil,
    lifecycleObserver: DictationLifecycleObserving? = nil,
    localReadiness: @escaping () -> Bool = {
      let model = LocalModelController.shared
      if !model.isReady { model.prepareIfNeeded() }
      return model.isReady
    },
    notifications: DictationNotificationPosting = SystemDictationNotifications()
  ) {
    self.localReadiness = localReadiness
    self.preferences = preferences
    self.credentials = credentials
    self.audio = audio
    self.transcriber = transcriber
    self.cleaner = cleaner
    self.muter = muter
    self.inserter = inserter ?? TextInsertionService(
      restoreEnabled: { [weak preferences] in preferences?.restoreClipboard == true },
      makeRestorationReport: { [weak runtimeDiagnostics] in
        let interactionID = runtimeDiagnostics?.currentInteractionID
        return { [weak runtimeDiagnostics] outcome in
          runtimeDiagnostics?.clipboardRestorationFinished(outcome, interactionID: interactionID)
        }
      })
    self.notch = notch
    self.benchmark = benchmark
    self.usageStats = usageStats
    self.readiness = readiness
    self.cuePlayer = cuePlayer
    self.runtimeDiagnostics = runtimeDiagnostics
    self.lifecycleObserver = lifecycleObserver
    self.notifications = notifications
    preferences.onClipboardRestorationChange = { [weak self] enabled in
      if !enabled { self?.inserter.invalidatePendingRestoration() }
    }
    audio.onAudio = { [weak self] data in
      DispatchQueue.main.async { self?.enqueue(data) }
    }
    transcriber.onTranscript = { [weak self] update in self?.updateTranscript(update) }
    transcriber.onAudioSent = { [weak self] count in
      guard let self, self.sessionID != nil else { return }
      self.benchmark.recordAudioSent(bytes: count)
    }
    transcriber.onError = { [weak self] error in
      guard let self, let id = self.sessionID else { return }
      let stage: BenchmarkFailureStage =
        self.phase == .starting && self.audioStopped ? .sttSetup : .sttStream
      self.fail(error, id: id, stage: stage)
    }
  }

  private var sessionVocabulary: [String] = []
  private let localReadiness: () -> Bool

  func prepareTranscriptionConnection() async -> Bool {
    guard !canCancel, !preferences.offlineMode,
      preferences.effectiveTranscriptionProvider == .grok,
      let key = credentials.value(for: .xai), !key.isEmpty else { return false }
    return await transcriber.prepareConnection(
      configuration: preferences.transcriptionConfiguration, apiKey: key,
      vocabulary: VocabularyNormalizer.normalize(preferences.vocabulary))
  }

  func invalidatePreparedConnection() { transcriber.invalidatePreparedConnection() }

  func prepareForLaunch(microphoneAuthorized: Bool) {
    guard !launchPreparationAttempted, preferences.onboardingComplete,
      microphoneAuthorized, phase == .idle
    else { runtimeDiagnostics?.preparationSkipped(); return }
    launchPreparationAttempted = true
    let credentials = self.credentials
    let audio = self.audio
    let transcriptionKind = preferences.effectiveTranscriptionProvider.credentialKind
    let cleanupKind: CredentialKind? = preferences.offlineMode ? nil : preferences.cleanupProvider.credentialKind
    let runtime = runtimeDiagnostics
    let preparationToken = runtime?.beginPreparation()
    let work = observeWork("launchPreparation")
    launchPreparationTask = Task.detached(priority: .utility) {
      async let audioPreparation = audio.prepareWithDiagnostics()
      if !Task.isCancelled, let transcriptionKind { _ = credentials.value(for: transcriptionKind) }
      if !Task.isCancelled, let cleanupKind { _ = credentials.value(for: cleanupKind) }
      let result = await audioPreparation
      if let preparationToken {
        await runtime?.finishPreparation(preparationToken, result: result)
      }
      if let work { await work.finish() }
    }
  }

  func toggle() {
    switch phase {
    case .idle, .success, .error:
      guard startTask == nil else { return }
      inserter.invalidatePendingRestoration()
      let transcriptionConfiguration = preferences.transcriptionConfiguration
      skipsCleanup = preferences.offlineMode
      let cleanupConfiguration = preferences.cleanupConfiguration
      let cleanupMode = preferences.cleanupMode
      sessionVocabulary = VocabularyNormalizer.normalize(preferences.vocabulary)
      activeTranscriptionConfiguration = transcriptionConfiguration
      activeCleanupSettings = ActiveCleanupSettings(
        instructions: CleanupInstructions(mode: cleanupMode,
          customInstructions: preferences.cleanupCustomInstructions),
        configuration: cleanupConfiguration)
      benchmark.begin(
        enabled: preferences.latencyLogging,
        transcriptionConfiguration: transcriptionConfiguration, cleanupMode: cleanupMode,
        cleanupConfiguration: cleanupConfiguration)
      let generation = UUID()
      lifecycleGeneration = generation
      phase = .starting
      let work = observeWork("start")
      startTask = Task { @MainActor [weak self] in
        defer { work?.finish() }
        await self?.start(generation: generation)
        if self?.lifecycleGeneration == generation { self?.startTask = nil }
      }
    case .starting:
      if audioStopped {
        cancel()
      } else {
        beginStopTask()
      }
    case .recording:
      beginStopTask()
    case .processing, .cleaning, .inserting: break
    }
  }

  func shortcutPressed() -> UUID? {
    let wasStartable: Bool
    switch phase {
    case .idle, .success, .error:
      wasStartable = startTask == nil
    case .starting, .recording, .processing, .cleaning, .inserting:
      wasStartable = false
    }
    toggle()
    return wasStartable && phase == .starting ? lifecycleGeneration : nil
  }

  func holdShortcutPressed() -> UUID? {
    switch phase {
    case .idle, .success, .error: return shortcutPressed()
    case .starting, .recording: return audioStopped ? nil : lifecycleGeneration
    case .processing, .cleaning, .inserting: return nil
    }
  }

  func finishHeldDictation(lifecycleGeneration: UUID) {
    guard self.lifecycleGeneration == lifecycleGeneration else { return }
    switch phase {
    case .starting:
      if audioStopped {
        cancel()
      } else {
        beginStopTask()
      }
    case .recording:
      beginStopTask()
    case .idle, .processing, .cleaning, .inserting, .success, .error:
      break
    }
  }

  func cancel() {
    invalidatePreparedConnection()
    inserter.invalidatePendingRestoration()
    launchPreparationTask?.cancel()
    launchPreparationTask = nil
    audio.discardPreparation()
    guard phase != .idle else {
      muter.restore()
      return
    }
    let cancellationGeneration = UUID()
    lifecycleGeneration = cancellationGeneration
    startTask?.cancel()
    startTask = nil
    cancelConnection()
    stopTask?.cancel()
    stopTask = nil
    targetCaptureTask?.cancel()
    targetCaptureTask = nil
    stopTaskID = nil
    if let session = usageSession { usageStats?.discard(session) }
    usageSession = nil
    sessionID = nil
    drainTask?.cancel()
    drainTask = nil
    drainTaskID = nil
    limitTask?.cancel()
    transcriber.cancel()
    stopAudioIfNeeded(playCue: false)
    benchmark.finish(
      .cancelled, stage: .lifecycle, category: .cancelled, httpStatus: nil)
    runtimeDiagnostics?.sessionCleanupFinished()
    activeTranscriptionConfiguration = nil
    activeCleanupSettings = nil
    phase = .error("Cancelled")
    state.phase = phase
    state.warning = nil
    notch.present(state: state)
    notch.hide(after: .milliseconds(600))
    let work = observeWork("cancellationIdleDelay")
    Task { @MainActor [weak self] in
      defer { work?.finish() }
      try? await Task.sleep(for: .milliseconds(650))
      guard let self, self.lifecycleGeneration == cancellationGeneration,
        self.sessionID == nil, self.phase == .error("Cancelled")
      else { return }
      self.phase = .idle
    }
  }

  private func start(generation: UUID) async {
    guard phase == .starting else { return }
    guard let transcriptionConfiguration = activeTranscriptionConfiguration else {
      showReadinessError(
        AppError.provider("Transcription settings were unavailable."), category: .unknown)
      return
    }
    let transcriptionProvider = transcriptionConfiguration.provider
    benchmark.mark(.credentialReadStarted)
    let transcriptionKey: String
    if let kind = transcriptionProvider.credentialKind {
      guard let key = credentials.value(for: kind), !key.isEmpty else {
        showReadinessError(transcriptionProvider.missingCredentialError, category: .missingCredential)
        return
      }
      transcriptionKey = key
    } else {
      guard localReadiness() else {
        showReadinessError(AppError.provider("Preparing Local model. Open Dictation settings if a download is needed, then press the shortcut again when ready."), category: .unknown)
        return
      }
      transcriptionKey = ""
    }
    guard let cleanupSettings = activeCleanupSettings else {
      showReadinessError(
        AppError.provider("Cleanup settings were unavailable."), category: .unknown)
      return
    }
    let cleanupProvider = cleanupSettings.configuration.provider
    let cleanupKey = skipsCleanup ? "" : (credentials.value(for: cleanupProvider.credentialKind) ?? "")
    guard skipsCleanup || !cleanupKey.isEmpty else {
      showReadinessError(cleanupProvider.missingCredentialError, category: .missingCredential)
      return
    }
    benchmark.mark(.credentialsReady)
    benchmark.mark(.readinessCheckStarted)
    let microphoneReady = await readiness.requestMicrophone()
    guard lifecycleGeneration == generation, !Task.isCancelled else { return }
    guard microphoneReady else {
      showReadinessError(AppError.microphoneUnavailable, category: .microphonePermission)
      return
    }
    guard readiness.accessibilityReady(prompt: true) else {
      showReadinessError(
        AppError.provider("Accessibility access is required to insert text."),
        category: .accessibilityPermission)
      return
    }

    benchmark.mark(.readinessChecksFinished)

    if !skipsCleanup, cleanupProvider == .cerebras {
      let cleaner = self.cleaner
      let work = observeWork("cleanupWarmUp")
      Task {
        defer { work?.finish() }
        await cleaner.warmUp(
          configuration: cleanupSettings.configuration, apiKey: cleanupKey)
      }
    }

    state = NotchState(phase: .starting)
    notch.present(state: state)
    let id = DictationSessionID()
    sessionID = id
    usageSession = usageStats?.begin()
    captureStartedAt = nil
    recordingSeconds = 0
    bufferedAudio.removeAll(keepingCapacity: true)
    bufferedBytes = 0
    connected = false

    beginTranscriberConnection(
      configuration: transcriptionConfiguration, apiKey: transcriptionKey, id: id)

    benchmark.mark(.startCuePlaybackStarted)
    play(.start)
    benchmark.mark(.startCuePlaybackReturned)
    if preferences.soundCues { try? await Task.sleep(for: cuePlayer.startCaptureDelay) }
    guard phase == .starting, lifecycleGeneration == generation, !Task.isCancelled else { return }

    benchmark.mark(.startCueDelayFinished)
    benchmark.mark(.outputMuteStarted)
    state.warning = preferences.muteOutput && !muter.mute() ? "Output could not be muted" : nil
    benchmark.mark(.outputMuteFinished)
    notch.present(state: state)
    audioStarting = true
    benchmark.mark(.audioEngineStartRequested)
    do {
      let usedPreparation = try await audio.start()
      guard lifecycleGeneration == generation, sessionID == id, !Task.isCancelled else { return }
      audioStarting = false
      audioStopped = false
      if usedPreparation { benchmark.mark(.preparedAudioEngineUsed) }
      captureStartedAt = .now
      benchmark.mark(.captureStarted)
    } catch {
      guard lifecycleGeneration == generation, sessionID == id, !Task.isCancelled else { return }
      fail(error, id: id, stage: .audioCapture)
      return
    }
    beginLimitTimer(id: id)

    guard sessionID == id, phase == .starting || phase == .processing else { return }
    if phase == .starting {
      phase = .recording
      state.phase = .recording
      notch.present(state: state)
    }
    drain()
  }

  private func beginTranscriberConnection(
    configuration: TranscriptionConfiguration, apiKey: String, id: DictationSessionID
  ) {
    guard connectionTask == nil else { return }
    let taskID = UUID()
    connectionTaskID = taskID
    let work = observeWork("connection")
    connectionTask = Task { @MainActor [weak self] in
      defer { work?.finish() }
      guard let self, !Task.isCancelled, self.sessionID == id else { return }
      _ = await self.connectTranscriber(configuration: configuration, apiKey: apiKey, id: id)
      guard self.connectionTaskID == taskID else { return }
      self.connectionTask = nil
      self.connectionTaskID = nil
    }
  }

  private func connectTranscriber(
    configuration: TranscriptionConfiguration, apiKey: String, id: DictationSessionID
  ) async -> Bool {
    do {
      try await transcriber.connect(
        configuration: configuration, apiKey: apiKey,
        vocabulary: sessionVocabulary, sessionID: id)
      guard sessionID == id,
        phase == .starting || phase == .recording || phase == .processing
      else { return false }
      benchmark.mark(.sttConfigured)
      connected = true
      drain()
      return true
    } catch {
      fail(error, id: id, stage: audioStopped ? .sttSetup : .sttStream)
      return false
    }
  }

  private func stop(targetCapture: Task<TextInsertionTarget?, Never>) async {
    guard let id = sessionID, phase == .starting || phase == .recording else { return }
    stopAudioIfNeeded(playCue: true)
    await flushPendingAudioCallbacks()
    benchmark.mark(.audioCallbacksFlushed)
    guard sessionID == id else { return }
    phase = .processing
    state.phase = .processing
    state.warning = nil
    notch.present(state: state)
    do {
      if !connected {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !connected, sessionID == id, ContinuousClock.now < deadline {
          try await Task.sleep(for: .milliseconds(25))
        }
        guard connected else { throw AppError.connectionTimeout }
      }
      drain()
      if let drainTask { await drainTask.value }
      guard sessionID == id, !Task.isCancelled else { return }
      try await transcriber.flushAudio()
      guard sessionID == id, !Task.isCancelled else { return }
      benchmark.mark(.audioQueueDrained)
      benchmark.mark(.sttFinalizeStarted)
      let raw = try await transcriber.finish()
      guard sessionID == id, !Task.isCancelled else { return }
      benchmark.mark(.sttFinalized)
      benchmark.recordRawCharacters(raw.count)
      guard sessionID == id else { return }
      let finalText: String
      if skipsCleanup {
        finalText = raw
      } else {
        phase = .cleaning
        state.phase = .cleaning
        notch.present(state: state)
        guard let cleanupSettings = activeCleanupSettings else {
          throw AppError.provider("Cleanup settings were unavailable.")
        }
        let cleanupProvider = cleanupSettings.configuration.provider
        guard let cleanupKey = credentials.value(for: cleanupProvider.credentialKind),
          !cleanupKey.isEmpty
        else {
          throw cleanupProvider.missingCredentialError
        }
        benchmark.recordCleanupMode(cleanupSettings.instructions.mode)
        benchmark.mark(.cleanupStarted)
        do {
          let cleanup = try await cleaner.clean(
            raw, instructions: cleanupSettings.instructions, configuration: cleanupSettings.configuration,
            apiKey: cleanupKey)
          guard sessionID == id else { return }
          finalText = cleanup.text
          benchmark.recordCleanup(cleanup.metrics)
        } catch {
          guard sessionID == id else { return }
          finalText = raw
          benchmark.recordCleanupFallback(rawCharacters: raw.count, error: error)
          state.warning = "Cleanup failed—used raw text"
          notch.present(state: state)
        }
        benchmark.mark(.cleanupFinished)
      }
      benchmark.recordCleanedCharacters(finalText.count)
      guard sessionID == id else { return }
      phase = .inserting
      state.phase = .inserting
      notch.present(state: state)
      let target = await targetCapture.value
      guard sessionID == id, !Task.isCancelled else { return }
      benchmark.mark(.insertionStarted)
      let result = await inserter.insert(finalText, into: target)
      guard sessionID == id else { return }
      benchmark.mark(.insertionFinished)
      switch result {
      case .pasteSent, .copied:
        if let session = usageSession {
          usageStats?.complete(session, words: UsageWordCounter.count(finalText),
                               recordingSeconds: recordingSeconds, at: Date())
          usageSession = nil
        }
      case .failed, .cancelled: break
      }
      switch result {
      case .pasteSent:
        benchmark.finish(.pasteSent, stage: nil, category: nil, httpStatus: nil)
        phase = .success
        state.phase = .success
        state.warning = nil
        notch.present(state: state)
        notch.hide(after: .milliseconds(700))
      case .failed(let warning):
        benchmark.finish(.failed, stage: .insertion, category: .unknown, httpStatus: nil)
        phase = .error(warning)
        state.phase = phase
        state.warning = warning
        notch.present(state: state)
        notch.hide(after: .seconds(3))
      case .cancelled:
        cancel()
        return
      case .copied(let reason):
        let warning = reason.copiedMessage
        benchmark.finish(
          .copied, stage: .insertion,
          category: BenchmarkFailureCategory(rawValue: reason.rawValue) ?? .unknown, httpStatus: nil
        )
        phase = .error(warning)
        state.phase = phase
        state.warning = warning
        notch.present(state: state)
        notch.hide(after: .seconds(2))
      }
      finishSession(id: id, preserveRestoration: result == .pasteSent)
      if result == .pasteSent { onSuccessfulSessionCompletion?() }
    } catch AppError.emptyTranscript {
      benchmark.finish(
        .emptyTranscript, stage: .sttFinalize, category: .emptyTranscript, httpStatus: nil)
      showTerminal("No speech detected", id: id, delay: .milliseconds(1200))
    } catch {
      fail(error, id: id, stage: phase == .cleaning ? .cleanup : .sttFinalize)
    }
  }

  private func enqueue(_ data: Data) {
    guard phase == .starting || phase == .recording else { return }
    let maximumBytes: Int
    if connected {
      maximumBytes =
        activeTranscriptionConfiguration?.provider.connectedBufferLimitBytes ?? 512_000
    } else {
      maximumBytes = 96_000
    }
    guard bufferedBytes + data.count <= maximumBytes else {
      if let id = sessionID {
        fail(
          AppError.provider("Audio could not keep up."), id: id, stage: .sttStream,
          category: .bufferOverflow)
      }
      return
    }
    bufferedAudio.append(data)
    bufferedBytes += data.count
    benchmark.recordAudioCaptured(bytes: data.count, bufferedBytes: bufferedBytes)
    if connected { drain() }
  }

  private func drain() {
    guard drainTask == nil, let id = sessionID else { return }
    let taskID = UUID()
    drainTaskID = taskID
    let work = observeWork("drain")
    drainTask = Task { @MainActor [weak self] in
      defer { work?.finish() }
      guard let self else { return }
      while self.sessionID == id, self.connected, !self.bufferedAudio.isEmpty,
        !Task.isCancelled
      {
        let data = self.bufferedAudio.removeFirst()
        self.bufferedBytes -= data.count
        do {
          try await self.transcriber.send(
            RealtimeAudioFrame(
              audio: data, queuedBytesAfterFrame: self.bufferedBytes))
          guard self.sessionID == id, !Task.isCancelled else { break }
          if !self.transcriber.reportsAudioSends {
            self.benchmark.recordAudioSent(bytes: data.count)
          }
        } catch {
          guard self.sessionID == id else { break }
          self.fail(error, id: id, stage: .sttStream)
          break
        }
      }
      if self.drainTaskID == taskID {
        self.drainTask = nil
        self.drainTaskID = nil
      }
    }
  }

  private func updateTranscript(_ update: RealtimeTranscriptUpdate) {
    benchmark.recordSTTUpdate(
      STTBenchmarkUpdate(
        hasTranscript: !update.snapshot.displayText.trimmingCharacters(
          in: .whitespacesAndNewlines
        ).isEmpty,
        hasFinalText: update.hasFinalText,
        finalAudioProcessedMS: update.finalAudioProcessedMS,
        totalAudioProcessedMS: update.totalAudioProcessedMS))
    guard phase == .recording || phase == .starting else { return }
    state.transcript = update.snapshot
    notch.present(state: state)
  }

  private func beginLimitTimer(id: DictationSessionID) {
    let work = observeWork("limit")
    limitTask = Task { @MainActor [weak self] in
      defer { work?.finish() }
      try? await Task.sleep(for: .seconds(600))
      guard let self else { return }
      guard self.sessionID == id else { return }
      self.beginStopTask()
    }
  }

  private func beginStopTask() {
    guard stopTask == nil else { return }
    benchmark.mark(.stopRequested)
    let taskID = UUID()
    stopTaskID = taskID
    stopAudioIfNeeded(playCue: true)
    let targetCapture = inserter.captureTarget()
    targetCaptureTask = targetCapture
    let work = observeWork("stop")
    stopTask = Task { @MainActor [weak self] in
      defer { work?.finish() }
      await self?.stop(targetCapture: targetCapture)
      guard let self, self.stopTaskID == taskID else { return }
      self.stopTask = nil
      self.stopTaskID = nil
    }
  }

  private func stopAudioIfNeeded(playCue: Bool) {
    guard !audioStopped || audioStarting else { return }
    audioStopped = true
    if let started = captureStartedAt {
      let duration = started.duration(to: .now).components
      recordingSeconds = Double(duration.seconds) + Double(duration.attoseconds) / 1e18
      captureStartedAt = nil
    }
    if audioStarting {
      startTask?.cancel()
      audio.cancelStart()
      audioStarting = false
    } else {
      audio.stop()
    }
    muter.restore()
    if playCue { play(.stop) }
    limitTask?.cancel()
  }

  private func flushPendingAudioCallbacks() async {
    await withCheckedContinuation { continuation in
      DispatchQueue.main.async { continuation.resume() }
    }
  }

  private func cancelDrain() {
    drainTask?.cancel()
    drainTask = nil
    drainTaskID = nil
  }

  private func cancelConnection() {
    connectionTask?.cancel()
    connectionTask = nil
    connectionTaskID = nil
  }

  private func fail(
    _ error: Error, id: DictationSessionID, stage: BenchmarkFailureStage,
    category explicitCategory: BenchmarkFailureCategory? = nil
  ) {
    guard sessionID == id else { return }
    let failure = benchmarkFailure(for: error)
    benchmark.finish(
      .failed, stage: stage, category: explicitCategory ?? failure.category,
      httpStatus: failure.httpStatus)
    cancelDrain()
    transcriber.cancel()
    stopAudioIfNeeded(playCue: false)
    play(.error)
    showTerminal(error.localizedDescription, id: id, delay: .seconds(2))
  }

  private func showTerminal(_ message: String, id: DictationSessionID, delay: Duration) {
    guard sessionID == id else { return }
    phase = .error(message)
    state.phase = phase
    notch.present(state: state)
    notch.hide(after: delay)
    finishSession(id: id)
  }

  private func finishSession(id: DictationSessionID, preserveRestoration: Bool = false) {
    guard sessionID == id else { return }
    if !preserveRestoration { inserter.invalidatePendingRestoration() }
    targetCaptureTask?.cancel()
    targetCaptureTask = nil
    cancelConnection()
    cancelDrain()
    stopAudioIfNeeded(playCue: false)
    connected = false
    bufferedAudio.removeAll()
    bufferedBytes = 0
    if let session = usageSession { usageStats?.discard(session) }
    usageSession = nil
    sessionID = nil
    activeTranscriptionConfiguration = nil
    activeCleanupSettings = nil
    runtimeDiagnostics?.sessionCleanupFinished()
    let generation = lifecycleGeneration
    let work = observeWork("terminalIdleDelay")
    Task { @MainActor [weak self] in
      defer { work?.finish() }
      try? await Task.sleep(for: .seconds(2.1))
      guard let self, self.lifecycleGeneration == generation, self.sessionID == nil else { return }
      self.phase = .idle
    }
  }

  private func showReadinessError(_ error: Error, category: BenchmarkFailureCategory) {
    benchmark.finish(.failed, stage: .readiness, category: category, httpStatus: nil)
    activeTranscriptionConfiguration = nil
    activeCleanupSettings = nil
    let generation = lifecycleGeneration
    phase = .error(error.localizedDescription)
    state = NotchState(phase: phase)
    notch.present(state: state)
    notch.hide(after: .seconds(2))
    notifications.postReadinessError(error)
    let work = observeWork("readinessIdleDelay")
    Task { @MainActor [weak self] in
      defer { work?.finish() }
      try? await Task.sleep(for: .seconds(2.1))
      guard let self, self.lifecycleGeneration == generation, self.sessionID == nil else { return }
      self.phase = .idle
    }
  }

  private func benchmarkFailure(for error: Error) -> (
    category: BenchmarkFailureCategory, httpStatus: Int?
  ) {
    if let error = error as? ProviderHTTPError {
      return (.provider, error.statusCode)
    }
    if let error = error as? GrokTransportError {
      return (error.isProviderRejection ? .provider : .network, error.httpStatus)
    }
    if error is CleanupNetworkError { return (.network, nil) }
    if error is URLError { return (.network, nil) }
    if let error = error as? AppError {
      switch error {
      case .missingSonioxKey, .missingMetaModelAPIKey, .missingXAIKey, .missingOpenRouterKey, .missingGroqKey,
        .missingCerebrasKey:
        return (.missingCredential, nil)
      case .microphoneUnavailable: return (.microphonePermission, nil)
      case .connectionTimeout: return (.connectionTimeout, nil)
      case .finalizeTimeout: return (.finalizeTimeout, nil)
      case .emptyTranscript: return (.emptyTranscript, nil)
      case .provider: return (.provider, nil)
      }
    }
    return (.unknown, nil)
  }

  private func observeWork(_ kind: String) -> DictationLifecycleWork? {
    guard let lifecycleObserver else { return nil }
    return DictationLifecycleWork(observer: lifecycleObserver, kind: kind)
  }

  private func play(_ cue: DictationCue) {
    guard preferences.soundCues else { return }
    cuePlayer.play(cue)
  }
}

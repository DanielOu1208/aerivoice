import AVFoundation
import AppKit

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
  private let benchmark: LatencyBenchmarkRecording
  private let capture: DictationCapture
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
  private(set) var bufferedBytes = 0
  private var connected = false
  /// What was buffered when the connection attempt began. Audio recorded before then, while
  /// the checks ran or queued behind a busy main thread, isn't charged to the time a
  /// connection may take.
  private var bytesBeforeConnectionAttempt: Int?
  /// Audio overflowed before start() opened a session to fail.
  private var audioOverflowedBeforeSession = false
  private var connectionTask: Task<Void, Never>?
  private var connectionTaskID: UUID?
  private var drainTask: Task<Void, Never>?
  private var limitTask: Task<Void, Never>?
  private var captureWarning: String?
  private var launchPreparationAttempted = false
  private var launchPreparationTask: Task<Void, Never>?
  private var lifecycleGeneration = UUID()
  private var startTask: Task<Void, Never>?
  private var stopTask: Task<Void, Never>?
  private var targetCaptureTask: Task<TextInsertionTarget?, Never>?
  private var stopTaskID: UUID?
  private var drainTaskID: UUID?
  var onSuccessfulSessionCompletion: (() -> Void)?
  /// Closed before an updater restart; all start paths converge on toggle().
  var acceptsNewSessions = true

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
      restoreDelay: { [weak preferences] in TimeInterval(preferences?.clipboardRestoreDelay ?? 5) },
      makeRestorationReport: { [weak runtimeDiagnostics] in
        let interactionID = runtimeDiagnostics?.currentInteractionID
        return { [weak runtimeDiagnostics] outcome in
          runtimeDiagnostics?.clipboardRestorationFinished(outcome, interactionID: interactionID)
        }
      })
    self.notch = notch
    self.benchmark = benchmark
    capture = DictationCapture(audio: audio, benchmark: benchmark)
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
    audio.onCaptureInterrupted = { [weak self] in
      DispatchQueue.main.async { self?.captureInterrupted() }
    }
    transcriber.onTranscript = { [weak self] update in self?.updateTranscript(update) }
    transcriber.onAudioSent = { [weak self] count in
      guard let self, self.sessionID != nil else { return }
      self.benchmark.recordAudioSent(bytes: count)
    }
    transcriber.onError = { [weak self] error in
      guard let self, let id = self.sessionID else { return }
      let stage: BenchmarkFailureStage =
        self.phase == .starting && !self.capture.isOpen ? .sttSetup : .sttStream
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

  /// Prepares the next microphone engine after wake or unlock, when no dictation is running.
  /// Preparing never opens the microphone, and an engine that is already prepared is kept.
  func prepareAudioIfIdle() {
    guard preferences.onboardingComplete, !canCancel, readiness.microphoneAuthorized else {
      return
    }
    let audio = self.audio
    let runtime = runtimeDiagnostics
    let preparationToken = runtime?.beginPreparation()
    let work = observeWork("audioPreparation")
    // Kept, so sleep or lock right after it can cancel it before it prepares anything.
    launchPreparationTask = Task.detached(priority: .utility) {
      let result = await audio.prepareWithDiagnostics()
      if let preparationToken {
        await runtime?.finishPreparation(preparationToken, result: result)
      }
      if let work { await work.finish() }
    }
  }

  func toggle() {
    switch phase {
    case .idle, .success, .error:
      guard acceptsNewSessions, startTask == nil else { return }
      let transcriptionConfiguration = preferences.transcriptionConfiguration
      skipsCleanup = preferences.offlineMode
      let cleanupConfiguration = preferences.cleanupConfiguration
      let cleanupMode = preferences.cleanupMode
      benchmark.begin(
        enabled: preferences.latencyLogging,
        transcriptionConfiguration: transcriptionConfiguration, cleanupMode: cleanupMode,
        cleanupConfiguration: cleanupConfiguration)
      // First, so the engine's own start-up overlaps everything below and the checks in start().
      startAudioEarlyIfPossible()
      let generation = UUID()
      lifecycleGeneration = generation
      phase = .starting
      inserter.prepareForNextDictation()
      sessionVocabulary = VocabularyNormalizer.normalize(preferences.vocabulary)
      activeTranscriptionConfiguration = transcriptionConfiguration
      activeCleanupSettings = ActiveCleanupSettings(
        instructions: CleanupInstructions(mode: cleanupMode,
          customInstructions: preferences.cleanupCustomInstructions),
        configuration: cleanupConfiguration)
      let work = observeWork("start")
      startTask = Task { @MainActor [weak self] in
        defer { work?.finish() }
        await self?.start(generation: generation)
        if self?.lifecycleGeneration == generation { self?.startTask = nil }
      }
    case .starting:
      if capture.isOpen {
        beginStopTask()
      } else {
        cancel()
      }
    case .recording:
      beginStopTask()
    case .processing, .cleaning, .inserting: break
    }
  }

  /// `eventAge` is how long ago the key event happened, recorded for a press that starts a
  /// dictation.
  func shortcutPressed(eventAge: Duration? = nil) -> UUID? {
    let wasStartable: Bool
    switch phase {
    case .idle, .success, .error:
      wasStartable = startTask == nil
    case .starting, .recording, .processing, .cleaning, .inserting:
      wasStartable = false
    }
    toggle()
    guard wasStartable, phase == .starting else { return nil }
    if let eventAge { benchmark.recordStep(.shortcutEventToActivation, eventAge) }
    return lifecycleGeneration
  }

  func holdShortcutPressed(eventAge: Duration? = nil) -> UUID? {
    switch phase {
    case .idle, .success, .error: return shortcutPressed(eventAge: eventAge)
    case .starting, .recording: return capture.isOpen ? lifecycleGeneration : nil
    case .processing, .cleaning, .inserting: return nil
    }
  }

  func finishForUpdateRestart() async {
    acceptsNewSessions = false
    if canCancel {
      for await phase in $phase.values {
        switch phase {
        case .starting, .recording, .processing, .cleaning, .inserting: continue
        default: break
        }
        break
      }
    }
    await inserter.finishPendingRestoration()
  }

  func finishHeldDictation(lifecycleGeneration: UUID) {
    guard self.lifecycleGeneration == lifecycleGeneration else { return }
    switch phase {
    case .starting:
      if capture.isOpen {
        beginStopTask()
      } else {
        cancel()
      }
    case .recording:
      beginStopTask()
    case .idle, .processing, .cleaning, .inserting, .success, .error:
      break
    }
  }

  /// A user cancel (Escape, menu Cancel, a second press during start-up, a cancelled
  /// insertion) prepares the next engine, even when the cancel came during engine start:
  /// saying it again right away is the usual next step.
  func cancel() { cancel(preparingNext: true) }

  /// Sleep, lock, a session switch and quit end any dictation and release the microphone
  /// engine, prepared or not.
  func cancelForSuspension() { cancel(preparingNext: false) }

  private func cancel(preparingNext: Bool) {
    invalidatePreparedConnection()
    inserter.invalidatePendingRestoration()
    if !preparingNext {
      launchPreparationTask?.cancel()
      launchPreparationTask = nil
      capture.discardPreparation()
    }
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
    stopAudioIfNeeded(playCue: false, prepareNext: preparingNext)
    resetAudioBuffer()
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

    if !skipsCleanup {
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
    captureWarning = nil
    // A microphone started at the press may already have delivered audio for this dictation.
    if !capture.startedEarly {
      bufferedAudio.removeAll(keepingCapacity: true)
      bufferedBytes = 0
      connected = false
      bytesBeforeConnectionAttempt = nil
      audioOverflowedBeforeSession = false
    }
    guard !audioOverflowedBeforeSession else {
      failAudioOverflow(id: id)
      return
    }

    beginTranscriberConnection(
      configuration: transcriptionConfiguration, apiKey: transcriptionKey, id: id)

    benchmark.mark(.startCuePlaybackStarted)
    play(.start)
    benchmark.mark(.startCuePlaybackReturned)
    // The microphone starts while the cue plays so its startup is hidden; the capture service
    // drops audio recorded before the deadline, keeping the loud part of the cue out.
    let cueDeadline =
      preferences.soundCues ? ContinuousClock.now.advanced(by: cuePlayer.startCaptureDelay) : nil
    if cueDeadline == nil {
      benchmark.mark(.startCueDelayFinished)
      muteOutput()
    }
    let report: AudioStartReport
    do {
      report = try await capture.start(discardingAudioBefore: cueDeadline)
    } catch {
      guard lifecycleGeneration == generation, sessionID == id, !Task.isCancelled else { return }
      fail(error, id: id, stage: .audioCapture)
      return
    }
    guard lifecycleGeneration == generation, sessionID == id, !Task.isCancelled else { return }
    benchmark.recordSteps(report)
    if let cueDeadline {
      try? await Task.sleep(until: cueDeadline)
      guard phase == .starting, lifecycleGeneration == generation, sessionID == id,
        !Task.isCancelled
      else { return }
      benchmark.mark(.startCueDelayFinished)
      muteOutput()
    }
    if report.usedPreparation { benchmark.mark(.preparedAudioEngineUsed) }
    capture.beganRecording()
    benchmark.mark(.captureStarted)
    beginLimitTimer(id: id)

    guard sessionID == id, phase == .starting || phase == .processing else { return }
    if phase == .starting {
      phase = .recording
      state.phase = .recording
      notch.present(state: state)
    }
    drain()
  }

  /// With sound cues off and microphone access already granted, the microphone starts at the
  /// press, before start() reads credentials and checks Accessibility and the local model. If
  /// a check then fails, the microphone stops and what it recorded is never sent. Output
  /// muting stays in start(): in the slow case a few milliseconds are recorded unmuted.
  private func startAudioEarlyIfPossible() {
    guard !preferences.soundCues, readiness.microphoneAuthorized else { return }
    resetAudioBuffer()
    capture.startEarly()
  }

  private func muteOutput() {
    benchmark.mark(.outputMuteStarted)
    state.warning = preferences.muteOutput && !muter.mute() ? "Output could not be muted" : nil
    benchmark.mark(.outputMuteFinished)
    notch.present(state: state)
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
      self.bytesBeforeConnectionAttempt = self.bufferedBytes
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
      fail(error, id: id, stage: capture.isOpen ? .sttStream : .sttSetup)
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
    state.warning = captureWarning
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
      if let steps = inserter.takeInsertionSteps() { benchmark.recordSteps(steps) }
      switch result {
      case .pasteSent, .copied:
        if let session = usageSession {
          usageStats?.complete(session, words: UsageWordCounter.count(finalText),
                               recordingSeconds: capture.recordingSeconds, at: Date())
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
    let streamLimit =
      activeTranscriptionConfiguration?.provider.connectedBufferLimitBytes ?? 512_000
    let maximumBytes: Int
    if let attempted = bytesBeforeConnectionAttempt {
      // About 3 s may wait for the connection, counted from when it was attempted. A backlog
      // from before then still fits once connected.
      let waiting = attempted + 96_000
      maximumBytes = connected ? max(streamLimit, waiting) : waiting
    } else {
      // Recorded before the connection was attempted: it waits like a stream's backlog.
      maximumBytes = streamLimit
    }
    guard bufferedBytes + data.count <= maximumBytes else {
      if let id = sessionID {
        failAudioOverflow(id: id)
      } else {
        // Dropping it would leave a hole in the speech.
        audioOverflowedBeforeSession = true
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
    // The microphone learns the release before anything else, so no audio after it is kept.
    let closingAudio = closeAudioAtRelease(mach_absolute_time())
    // The insertion target is the app focused at release.
    let pinStarted = ContinuousClock.now
    let targetCapture = inserter.captureTarget()
    benchmark.recordStep(.targetPin, pinStarted.duration(to: .now))
    targetCaptureTask = targetCapture
    let work = observeWork("stop")
    stopTask = Task { @MainActor [weak self] in
      defer { work?.finish() }
      if let closingAudio { await self?.finishClosingAudio(closingAudio) }
      await self?.stop(targetCapture: targetCapture)
      guard let self, self.stopTaskID == taskID else { return }
      self.stopTask = nil
      self.stopTaskID = nil
    }
  }

  private func captureInterrupted() {
    guard phase == .starting || phase == .recording else { return }
    guard let id = sessionID else {
      // The microphone started at the press and start() is still checking: it fails once it
      // takes the microphone over.
      capture.inputLostBeforeSession()
      return
    }
    if capture.isStarting {
      fail(AppError.microphoneUnavailable, id: id, stage: .audioCapture)
    } else if capture.isOpen {
      // Keep what was captured before the input disappeared.
      captureWarning = "Microphone disconnected"
      state.warning = captureWarning
      notch.present(state: state)
      beginStopTask()
    }
  }

  /// A running microphone keeps recording until the block holding the release arrives. One
  /// still starting stops at once.
  private func closeAudioAtRelease(_ release: UInt64) -> DictationCapture.Closing? {
    if let closing = capture.beginClose(atRelease: release) { return closing }
    if let audioStop = stopAudioIfNeeded(playCue: true) {
      benchmark.recordStep(.audioStop, audioStop)
    }
    return nil
  }

  /// The stop cue plays once the microphone has closed, so it is never transcribed.
  private func finishClosingAudio(_ closing: DictationCapture.Closing) async {
    // A cancel or failure during the wait already stopped capture and finished up.
    guard await capture.finishClose(closing) else { return }
    finishAudioStop(playCue: true, prepareNext: true)
    benchmark.recordStep(.audioStop, closing.requested.duration(to: .now))
  }

  private func finishAudioStop(playCue: Bool, prepareNext: Bool) {
    if prepareNext { capture.prepareNext() }
    muter.restore()
    if playCue { play(.stop) }
    limitTask?.cancel()
  }

  /// Returns how long closing a running microphone took.
  @discardableResult
  private func stopAudioIfNeeded(playCue: Bool, prepareNext: Bool = true) -> Duration? {
    guard capture.isStarting || capture.isOpen else { return nil }
    if capture.isStarting { startTask?.cancel() }
    let stopDuration = capture.stop()
    finishAudioStop(playCue: playCue, prepareNext: prepareNext)
    return stopDuration
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
    let failure = BenchmarkFailureCategory.classify(error)
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
    resetAudioBuffer()
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

  private func resetAudioBuffer() {
    connected = false
    bufferedAudio.removeAll()
    bufferedBytes = 0
    bytesBeforeConnectionAttempt = nil
    audioOverflowedBeforeSession = false
  }

  private func failAudioOverflow(id: DictationSessionID) {
    fail(
      AppError.provider("Audio could not keep up."), id: id, stage: .sttStream,
      category: .bufferOverflow)
  }

  private func showReadinessError(_ error: Error, category: BenchmarkFailureCategory) {
    // A check failed after the microphone started at the press: keep nothing it recorded.
    if capture.abandonEarlyStart() { resetAudioBuffer() }
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

  private func observeWork(_ kind: String) -> DictationLifecycleWork? {
    guard let lifecycleObserver else { return nil }
    return DictationLifecycleWork(observer: lifecycleObserver, kind: kind)
  }

  private func play(_ cue: DictationCue) {
    guard preferences.soundCues else { return }
    cuePlayer.play(cue)
  }
}

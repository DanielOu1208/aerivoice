import AVFoundation
import AppKit
import UserNotifications

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
    let mode: CleanupMode
    let configuration: CleanupConfiguration
  }

  @Published private(set) var phase: DictationPhase = .idle

  private let preferences: AppPreferences
  private let credentials: CredentialReading
  private let audio: AudioCapturing
  private let transcriber: RealtimeTranscribing
  private let cleaner: CleaningText
  private let muter: OutputMuting
  private let inserter: TextInserting
  private let notch: NotchPresenting
  private let benchmark: LatencyBenchmarkRecording
  private let readiness: DictationReadinessChecking
  private let cuePlayer: SoundCuePlaying

  private var sessionID: DictationSessionID?
  private var activeTranscriptionConfiguration: TranscriptionConfiguration?
  private var activeCleanupSettings: ActiveCleanupSettings?
  private var state = NotchState(phase: .idle)
  private var bufferedAudio: [Data] = []
  private var bufferedBytes = 0
  private var connected = false
  private var connectionTask: Task<Void, Never>?
  private var connectionTaskID: UUID?
  private var drainTask: Task<Void, Never>?
  private var limitTask: Task<Void, Never>?
  private var audioStopped = true
  private var lifecycleGeneration = UUID()
  private var startTask: Task<Void, Never>?
  private var stopTask: Task<Void, Never>?
  private var stopTaskID: UUID?
  private var drainTaskID: UUID?

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
    inserter: TextInserting = TextInsertionService(), notch: NotchPresenting = NotchPresenter(),
    benchmark: LatencyBenchmarkRecording = LatencyBenchmarkRecorder(),
    readiness: DictationReadinessChecking = SystemDictationReadiness(),
    cuePlayer: SoundCuePlaying = SoundCuePlayer()
  ) {
    self.preferences = preferences
    self.credentials = credentials
    self.audio = audio
    self.transcriber = transcriber
    self.cleaner = cleaner
    self.muter = muter
    self.inserter = inserter
    self.notch = notch
    self.benchmark = benchmark
    self.readiness = readiness
    self.cuePlayer = cuePlayer
    audio.onAudio = { [weak self] data in
      DispatchQueue.main.async { self?.enqueue(data) }
    }
    transcriber.onTranscript = { [weak self] update in self?.updateTranscript(update) }
    transcriber.onError = { [weak self] error in
      guard let self, let id = self.sessionID else { return }
      let stage: BenchmarkFailureStage =
        self.phase == .starting && self.audioStopped ? .sttSetup : .sttStream
      self.fail(error, id: id, stage: stage)
    }
  }

  func toggle() {
    switch phase {
    case .idle, .success, .error:
      guard startTask == nil else { return }
      let transcriptionConfiguration = TranscriptionConfiguration(
        provider: preferences.transcriptionProvider)
      let cleanupConfiguration = preferences.cleanupConfiguration
      let cleanupMode = preferences.cleanupMode
      activeTranscriptionConfiguration = transcriptionConfiguration
      activeCleanupSettings = ActiveCleanupSettings(
        mode: cleanupMode, configuration: cleanupConfiguration)
      benchmark.begin(
        enabled: preferences.latencyLogging,
        transcriptionConfiguration: transcriptionConfiguration, cleanupMode: cleanupMode,
        cleanupConfiguration: cleanupConfiguration)
      let generation = UUID()
      lifecycleGeneration = generation
      phase = .starting
      startTask = Task { @MainActor [weak self] in
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
    stopTaskID = nil
    sessionID = nil
    drainTask?.cancel()
    drainTask = nil
    drainTaskID = nil
    limitTask?.cancel()
    transcriber.cancel()
    stopAudioIfNeeded(playCue: false)
    benchmark.finish(
      .cancelled, stage: .lifecycle, category: .cancelled, httpStatus: nil)
    activeTranscriptionConfiguration = nil
    activeCleanupSettings = nil
    phase = .error("Cancelled")
    state.phase = phase
    state.warning = nil
    notch.present(state: state)
    notch.hide(after: .milliseconds(600))
    Task { @MainActor [weak self] in
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
    guard
      let transcriptionKey = credentials.value(for: transcriptionProvider.credentialKind),
      !transcriptionKey.isEmpty
    else {
      showReadinessError(
        transcriptionProvider.missingCredentialError, category: .missingCredential)
      return
    }
    guard let cleanupSettings = activeCleanupSettings else {
      showReadinessError(
        AppError.provider("Cleanup settings were unavailable."), category: .unknown)
      return
    }
    let cleanupProvider = cleanupSettings.configuration.provider
    guard credentials.value(for: cleanupProvider.credentialKind).map({ !$0.isEmpty }) == true else {
      showReadinessError(cleanupProvider.missingCredentialError, category: .missingCredential)
      return
    }
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

    state = NotchState(phase: .starting)
    notch.present(state: state)
    let id = DictationSessionID()
    sessionID = id
    bufferedAudio.removeAll(keepingCapacity: true)
    bufferedBytes = 0
    connected = false

    if transcriptionProvider == .meta {
      beginTranscriberConnection(
        configuration: transcriptionConfiguration, apiKey: transcriptionKey, id: id)
    }

    play(.start)
    if preferences.soundCues { try? await Task.sleep(for: cuePlayer.startCaptureDelay) }
    guard phase == .starting, lifecycleGeneration == generation, !Task.isCancelled else { return }

    state.warning = preferences.muteOutput && !muter.mute() ? "Output could not be muted" : nil
    notch.present(state: state)
    audioStopped = false
    do {
      try audio.start()
      benchmark.mark(.captureStarted)
    } catch {
      fail(error, id: id, stage: .audioCapture)
      return
    }
    beginLimitTimer(id: id)

    if transcriptionProvider != .meta {
      guard
        await connectTranscriber(
          configuration: transcriptionConfiguration, apiKey: transcriptionKey, id: id)
      else { return }
    }

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
    connectionTask = Task { @MainActor [weak self] in
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
        vocabulary: VocabularyNormalizer.normalize(preferences.vocabulary), sessionID: id)
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

  private func stop() async {
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
      benchmark.mark(.audioQueueDrained)
      guard sessionID == id else { return }
      benchmark.mark(.sttFinalizeStarted)
      let raw = try await transcriber.finish()
      benchmark.mark(.sttFinalized)
      benchmark.recordRawCharacters(raw.count)
      guard sessionID == id else { return }
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
      benchmark.recordCleanupMode(cleanupSettings.mode)
      benchmark.mark(.cleanupStarted)
      let finalText: String
      do {
        let cleanup = try await cleaner.clean(
          raw, mode: cleanupSettings.mode, configuration: cleanupSettings.configuration,
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
      benchmark.recordCleanedCharacters(finalText.count)
      benchmark.mark(.cleanupFinished)
      guard sessionID == id else { return }
      phase = .inserting
      state.phase = .inserting
      notch.present(state: state)
      benchmark.mark(.insertionStarted)
      let result = await inserter.insert(finalText)
      benchmark.mark(.insertionFinished)
      guard sessionID == id else { return }
      switch result {
      case .inserted:
        benchmark.finish(.inserted, stage: nil, category: nil, httpStatus: nil)
        phase = .success
        state.phase = .success
        state.warning = nil
        notch.present(state: state)
        notch.hide(after: .milliseconds(350))
      case .copied(let warning):
        benchmark.finish(.copied, stage: nil, category: nil, httpStatus: nil)
        phase = .error(warning)
        state.phase = phase
        state.warning = warning
        notch.present(state: state)
        notch.hide(after: .seconds(2))
      }
      finishSession(id: id)
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
    drainTask = Task { @MainActor [weak self] in
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
          self.benchmark.recordAudioSent(bytes: data.count)
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
    limitTask = Task { @MainActor [weak self] in
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
    stopTask = Task { @MainActor [weak self] in
      await self?.stop()
      guard let self, self.stopTaskID == taskID else { return }
      self.stopTask = nil
      self.stopTaskID = nil
    }
  }

  private func stopAudioIfNeeded(playCue: Bool) {
    guard !audioStopped else { return }
    audioStopped = true
    audio.stop()
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

  private func finishSession(id: DictationSessionID) {
    guard sessionID == id else { return }
    cancelConnection()
    cancelDrain()
    stopAudioIfNeeded(playCue: false)
    connected = false
    bufferedAudio.removeAll()
    bufferedBytes = 0
    sessionID = nil
    activeTranscriptionConfiguration = nil
    activeCleanupSettings = nil
    let generation = lifecycleGeneration
    Task { @MainActor [weak self] in
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
    let notification = UNMutableNotificationContent()
    notification.title = "AeriVoice needs attention"
    notification.body = error.localizedDescription
    notification.categoryIdentifier = "OPEN_SETTINGS"
    let request = UNNotificationRequest(
      identifier: UUID().uuidString, content: notification, trigger: nil)
    UNUserNotificationCenter.current().add(request)
    Task { @MainActor [weak self] in
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
    if error is URLError { return (.network, nil) }
    if let error = error as? AppError {
      switch error {
      case .missingSonioxKey, .missingMetaModelAPIKey, .missingOpenRouterKey, .missingGroqKey:
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

  private func play(_ cue: DictationCue) {
    guard preferences.soundCues else { return }
    cuePlayer.play(cue)
  }
}

import AVFoundation
import AppKit
import UserNotifications

@MainActor
final class DictationCoordinator: ObservableObject {
  @Published private(set) var phase: DictationPhase = .idle

  private let preferences: AppPreferences
  private let credentials: KeychainStore
  private let audio: AudioCapturing
  private let transcriber: RealtimeTranscribing
  private let cleaner: CleaningText
  private let muter: OutputMuting
  private let inserter: TextInserting
  private let notch: NotchPresenting

  private var sessionID: DictationSessionID?
  private var state = NotchState(phase: .idle)
  private var bufferedAudio: [Data] = []
  private var bufferedBytes = 0
  private var connected = false
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
    preferences: AppPreferences, credentials: KeychainStore,
    audio: AudioCapturing = AudioCaptureService(),
    transcriber: RealtimeTranscribing = SonioxRealtimeClient(),
    cleaner: CleaningText = OpenRouterCleanupClient(), muter: OutputMuting = OutputMuteController(),
    inserter: TextInserting = TextInsertionService(), notch: NotchPresenting = NotchPresenter()
  ) {
    self.preferences = preferences
    self.credentials = credentials
    self.audio = audio
    self.transcriber = transcriber
    self.cleaner = cleaner
    self.muter = muter
    self.inserter = inserter
    self.notch = notch
    audio.onAudio = { [weak self] data in
      DispatchQueue.main.async { self?.enqueue(data) }
    }
    transcriber.onTranscript = { [weak self] snapshot in self?.updateTranscript(snapshot) }
    transcriber.onError = { [weak self] error in
      guard let self, let id = self.sessionID else { return }
      self.fail(error, id: id)
    }
  }

  func toggle() {
    switch phase {
    case .idle, .success, .error:
      guard startTask == nil else { return }
      let generation = UUID()
      lifecycleGeneration = generation
      startTask = Task { @MainActor [weak self] in
        await self?.start(generation: generation)
        if self?.lifecycleGeneration == generation { self?.startTask = nil }
      }
    case .starting, .recording:
      beginStopTask()
    case .processing, .cleaning, .inserting: break
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
    guard phase == .idle || phase.isTerminal else { return }
    guard let sonioxKey = credentials.value(for: .soniox), !sonioxKey.isEmpty else {
      showReadinessError(AppError.missingSonioxKey)
      return
    }
    guard credentials.value(for: .openRouter).map({ !$0.isEmpty }) == true else {
      showReadinessError(AppError.missingOpenRouterKey)
      return
    }
    guard await requestMicrophone() else {
      showReadinessError(AppError.microphoneUnavailable)
      return
    }
    guard lifecycleGeneration == generation, !Task.isCancelled else { return }
    guard AXIsProcessTrusted() else {
      let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
      _ = AXIsProcessTrustedWithOptions(options)
      showReadinessError(AppError.provider("Accessibility access is required to insert text."))
      return
    }

    let id = DictationSessionID()
    sessionID = id
    phase = .starting
    state = NotchState(phase: .starting)
    notch.present(state: state)
    play(.start)
    if preferences.soundCues { try? await Task.sleep(for: .milliseconds(60)) }
    guard sessionID == id, lifecycleGeneration == generation, !Task.isCancelled else { return }
    state.warning = preferences.muteOutput && !muter.mute() ? "Output could not be muted" : nil
    notch.present(state: state)
    audioStopped = false
    bufferedAudio.removeAll(keepingCapacity: true)
    bufferedBytes = 0
    connected = false
    do {
      try audio.start()
    } catch {
      fail(error, id: id)
      return
    }
    beginLimitTimer(id: id)

    do {
      try await transcriber.connect(
        apiKey: sonioxKey, vocabulary: VocabularyNormalizer.normalize(preferences.vocabulary),
        sessionID: id)
      guard sessionID == id, phase == .starting || phase == .processing else { return }
      connected = true
      if phase == .starting {
        phase = .recording
        state.phase = .recording
        notch.present(state: state)
      }
      drain()
    } catch {
      fail(error, id: id)
    }
  }

  private func stop() async {
    guard let id = sessionID, phase == .starting || phase == .recording else { return }
    stopAudioIfNeeded(playCue: true)
    await flushPendingAudioCallbacks()
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
      guard sessionID == id else { return }
      let raw = try await transcriber.finish()
      guard sessionID == id else { return }
      guard let openRouterKey = credentials.value(for: .openRouter) else {
        throw AppError.missingOpenRouterKey
      }
      phase = .cleaning
      state.phase = .cleaning
      notch.present(state: state)
      let finalText: String
      do {
        finalText = try await cleaner.clean(
          raw, mode: preferences.cleanupMode, apiKey: openRouterKey)
      } catch {
        finalText = raw
        state.warning = "Cleanup failed—used raw text"
        notch.present(state: state)
      }
      guard sessionID == id else { return }
      phase = .inserting
      state.phase = .inserting
      notch.present(state: state)
      let result = await inserter.insert(finalText)
      guard sessionID == id else { return }
      switch result {
      case .inserted:
        phase = .success
        state.phase = .success
        state.warning = nil
        notch.present(state: state)
        notch.hide(after: .milliseconds(350))
      case .copied(let warning):
        phase = .error(warning)
        state.phase = phase
        state.warning = warning
        notch.present(state: state)
        notch.hide(after: .seconds(2))
      }
      finishSession(id: id)
    } catch AppError.emptyTranscript {
      showTerminal("No speech detected", id: id, delay: .milliseconds(1200))
    } catch {
      fail(error, id: id)
    }
  }

  private func enqueue(_ data: Data) {
    guard phase == .starting || phase == .recording else { return }
    let maximumBytes = connected ? 512_000 : 96_000
    guard bufferedBytes + data.count <= maximumBytes else {
      if let id = sessionID { fail(AppError.provider("Audio could not keep up."), id: id) }
      return
    }
    bufferedAudio.append(data)
    bufferedBytes += data.count
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
        do { try await self.transcriber.send(data) } catch {
          guard self.sessionID == id else { break }
          self.fail(error, id: id)
          break
        }
      }
      if self.drainTaskID == taskID {
        self.drainTask = nil
        self.drainTaskID = nil
      }
    }
  }

  private func updateTranscript(_ snapshot: TranscriptSnapshot) {
    guard phase == .recording || phase == .starting else { return }
    state.transcript = snapshot
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
    let taskID = UUID()
    stopTaskID = taskID
    stopTask = Task { @MainActor [weak self] in
      await self?.stop()
      guard let self, self.stopTaskID == taskID else { return }
      self.stopTask = nil
      self.stopTaskID = nil
    }
  }

  private func requestMicrophone() async -> Bool {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized: true
    case .notDetermined: await AVCaptureDevice.requestAccess(for: .audio)
    default: false
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

  private func fail(_ error: Error, id: DictationSessionID) {
    guard sessionID == id else { return }
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
    cancelDrain()
    stopAudioIfNeeded(playCue: false)
    connected = false
    bufferedAudio.removeAll()
    bufferedBytes = 0
    sessionID = nil
    let generation = lifecycleGeneration
    Task { @MainActor [weak self] in
      try? await Task.sleep(for: .seconds(2.1))
      guard let self, self.lifecycleGeneration == generation, self.sessionID == nil else { return }
      self.phase = .idle
    }
  }

  private func showReadinessError(_ error: Error) {
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

  private enum Cue { case start, stop, error }
  private func play(_ cue: Cue) {
    guard preferences.soundCues else { return }
    let name: NSSound.Name =
      switch cue {
      case .start: "Tink"
      case .stop: "Pop"
      case .error: "Basso"
      }
    NSSound(named: name)?.play()
  }
}

extension DictationPhase {
  fileprivate var isTerminal: Bool {
    switch self {
    case .success, .error: true
    default: false
    }
  }
}

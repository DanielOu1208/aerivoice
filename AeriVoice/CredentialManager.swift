import Foundation

@MainActor
protocol CredentialValidating {
  func validate(
    _ value: String, kind: CredentialKind, configuration: CleanupConfiguration?
  ) async throws
}

@MainActor
struct LiveCredentialValidator: CredentialValidating {
  func validate(
    _ value: String, kind: CredentialKind, configuration: CleanupConfiguration?
  ) async throws {
    switch kind {
    case .openRouter:
      guard let configuration, configuration.provider == .openRouter else {
        throw AppError.provider("OpenRouter validation configuration is missing.")
      }
      try await OpenRouterCleanupClient().validate(
        apiKey: value, configuration: configuration)
    case .groq:
      guard let configuration, configuration.provider == .groq else {
        throw AppError.provider("Groq validation configuration is missing.")
      }
      try await GroqCleanupClient().validate(apiKey: value, model: configuration.model)
    case .cerebras:
      guard let configuration, configuration.provider == .cerebras else {
        throw AppError.provider("Cerebras validation configuration is missing.")
      }
      try await CerebrasCleanupClient().validate(apiKey: value, model: configuration.model)
    case .soniox:
      let client = SonioxRealtimeClient()
      defer { client.cancel() }
      try await client.connect(
        configuration: TranscriptionConfiguration(provider: .soniox), apiKey: value,
        vocabulary: [], sessionID: DictationSessionID())
      try await client.send(
        RealtimeAudioFrame(
          audio: Data(repeating: 0, count: 3_200), queuedBytesAfterFrame: 0))
      do { _ = try await client.finish() } catch AppError.emptyTranscript {}
    case .metaModelAPI:
      let client = MetaRealtimeClient()
      defer { client.cancel() }
      try await client.connect(
        configuration: TranscriptionConfiguration(provider: .meta), apiKey: value,
        vocabulary: [], sessionID: DictationSessionID())
      try await client.send(
        RealtimeAudioFrame(
          audio: Data(repeating: 0, count: 3_200), queuedBytesAfterFrame: 0))
      do { _ = try await client.finish() } catch AppError.emptyTranscript {}
    }
  }
}

enum LegacyCredentialImportError: LocalizedError {
  case unavailable

  var errorDescription: String? {
    "macOS couldn’t read this beta.1 key. Paste it again below to reconnect."
  }
}

@MainActor
final class CredentialManager: ObservableObject {
  @Published private var statuses: [CredentialKind: CredentialStatus]

  private let store: CredentialStoring
  private let legacyStore: CredentialPresenceReading?
  private let validator: CredentialValidating
  private var storedCredentialKinds: Set<CredentialKind>
  private var legacyCredentialKinds: Set<CredentialKind>
  private var validationTasks: [CredentialKind: Task<Void, Never>] = [:]
  private var validationGenerations: [CredentialKind: UUID] = [:]

  init(
    store: CredentialStoring,
    legacyStore: CredentialPresenceReading? = nil,
    validator: CredentialValidating = LiveCredentialValidator()
  ) {
    self.store = store
    self.legacyStore = legacyStore
    self.validator = validator
    let loadedCredentialKinds = Set(
      CredentialKind.allCases.filter(store.containsCredential))
    let loadedLegacyCredentialKinds = Set(
      CredentialKind.allCases.filter { legacyStore?.containsCredential($0) == true })
    storedCredentialKinds = loadedCredentialKinds
    legacyCredentialKinds = loadedLegacyCredentialKinds
    statuses = Dictionary(
      uniqueKeysWithValues: CredentialKind.allCases.map {
        ($0, loadedCredentialKinds.contains($0) ? .saved : .missing)
      })
  }

  func refreshStoredCredentials() {
    let refreshedKinds = Set(CredentialKind.allCases.filter(store.containsCredential))
    let refreshedLegacyKinds = Set(
      CredentialKind.allCases.filter { legacyStore?.containsCredential($0) == true })
    storedCredentialKinds = refreshedKinds
    legacyCredentialKinds = refreshedLegacyKinds
    statuses = Dictionary(
      uniqueKeysWithValues: CredentialKind.allCases.map { kind in
        let currentStatus = statuses[kind] ?? .missing
        switch currentStatus {
        case .validating, .error:
          return (kind, currentStatus)
        case .saved, .missing:
          return (kind, refreshedKinds.contains(kind) ? .saved : .missing)
        }
      })
  }

  func hasCredential(_ kind: CredentialKind) -> Bool {
    storedCredentialKinds.contains(kind)
  }

  func canImportLegacyCredential(_ kind: CredentialKind) -> Bool {
    !storedCredentialKinds.contains(kind) && legacyCredentialKinds.contains(kind)
  }

  func status(for kind: CredentialKind) -> CredentialStatus {
    statuses[kind] ?? .missing
  }

  func beginValidation(
    _ value: String, kind: CredentialKind, configuration: CleanupConfiguration?
  ) {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      statuses[kind] = .error("Enter a key first.")
      return
    }

    invalidateValidation(kind)
    let generation = UUID()
    validationGenerations[kind] = generation
    statuses[kind] = .validating
    validationTasks[kind] = Task { [weak self, validator, store] in
      do {
        try await validator.validate(trimmed, kind: kind, configuration: configuration)
        try Task.checkCancellation()
        guard let self, self.validationGenerations[kind] == generation else { return }
        try store.save(trimmed, for: kind)
        self.storedCredentialKinds.insert(kind)
        self.finishValidation(.saved, kind: kind, generation: generation)
      } catch is CancellationError {
        self?.restoreStoredStatusIfCurrent(kind: kind, generation: generation)
      } catch {
        self?.finishValidation(
          .error(error.localizedDescription), kind: kind, generation: generation)
      }
    }
  }

  func beginLegacyImport(
    kind: CredentialKind, configuration: CleanupConfiguration?
  ) {
    guard !hasCredential(kind) else {
      statuses[kind] = .saved
      return
    }
    guard canImportLegacyCredential(kind), let legacyStore else {
      statuses[kind] = .error(LegacyCredentialImportError.unavailable.localizedDescription)
      return
    }

    invalidateValidation(kind)
    let generation = UUID()
    validationGenerations[kind] = generation
    statuses[kind] = .validating
    validationTasks[kind] = Task { [weak self, validator, store, legacyStore] in
      do {
        try Task.checkCancellation()
        guard
          let value = legacyStore.value(for: kind)?.trimmingCharacters(
            in: .whitespacesAndNewlines),
          !value.isEmpty
        else { throw LegacyCredentialImportError.unavailable }
        try await validator.validate(value, kind: kind, configuration: configuration)
        try Task.checkCancellation()
        guard let self, self.validationGenerations[kind] == generation else { return }
        _ = try store.addIfMissing(value, for: kind)
        self.storedCredentialKinds.insert(kind)
        self.finishValidation(.saved, kind: kind, generation: generation)
      } catch is CancellationError {
        self?.restoreStoredStatusIfCurrent(kind: kind, generation: generation)
      } catch {
        self?.finishValidation(
          .error(error.localizedDescription), kind: kind, generation: generation)
      }
    }
  }

  func cancelValidation(_ kind: CredentialKind) {
    invalidateValidation(kind)
    statuses[kind] = storedStatus(for: kind)
  }

  func remove(_ kind: CredentialKind) {
    invalidateValidation(kind)
    do {
      try store.remove(kind)
      storedCredentialKinds.remove(kind)
      statuses[kind] = .missing
    } catch {
      statuses[kind] = .error(error.localizedDescription)
    }
  }

  private func invalidateValidation(_ kind: CredentialKind) {
    validationGenerations[kind] = nil
    validationTasks[kind]?.cancel()
    validationTasks[kind] = nil
  }

  private func finishValidation(
    _ status: CredentialStatus, kind: CredentialKind, generation: UUID
  ) {
    guard validationGenerations[kind] == generation else { return }
    statuses[kind] = status
    validationGenerations[kind] = nil
    validationTasks[kind] = nil
  }

  private func restoreStoredStatusIfCurrent(kind: CredentialKind, generation: UUID) {
    guard validationGenerations[kind] == generation else { return }
    finishValidation(storedStatus(for: kind), kind: kind, generation: generation)
  }

  private func storedStatus(for kind: CredentialKind) -> CredentialStatus {
    hasCredential(kind) ? .saved : .missing
  }
}

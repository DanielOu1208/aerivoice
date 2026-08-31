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
    case .soniox:
      let client = SonioxRealtimeClient()
      defer { client.cancel() }
      try await client.connect(apiKey: value, vocabulary: [], sessionID: DictationSessionID())
      try await client.send(Data(repeating: 0, count: 3_200))
      do { _ = try await client.finish() } catch AppError.emptyTranscript {}
    }
  }
}

@MainActor
final class CredentialManager: ObservableObject {
  @Published private var statuses: [CredentialKind: CredentialStatus]

  private let store: CredentialStoring
  private let validator: CredentialValidating
  private var validationTasks: [CredentialKind: Task<Void, Never>] = [:]
  private var validationGenerations: [CredentialKind: UUID] = [:]

  init(
    store: CredentialStoring,
    validator: CredentialValidating = LiveCredentialValidator()
  ) {
    self.store = store
    self.validator = validator
    statuses = Dictionary(
      uniqueKeysWithValues: CredentialKind.allCases.map {
        let hasCredential = store.value(for: $0).map { !$0.isEmpty } == true
        return ($0, hasCredential ? .saved : .missing)
      })
  }

  func hasCredential(_ kind: CredentialKind) -> Bool {
    store.value(for: kind).map { !$0.isEmpty } == true
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

import Foundation

struct CleanupClientRouter: CleaningText {
  private let openRouter: OpenRouterCleanupClient
  private let groq: GroqCleanupClient
  private let cerebras: CerebrasCleanupClient

  init(
    openRouter: OpenRouterCleanupClient = OpenRouterCleanupClient(),
    groq: GroqCleanupClient = GroqCleanupClient(),
    cerebras: CerebrasCleanupClient = CerebrasCleanupClient()
  ) {
    self.openRouter = openRouter
    self.groq = groq
    self.cerebras = cerebras
  }

  func clean(
    _ text: String, mode: CleanupMode, configuration: CleanupConfiguration, apiKey: String
  ) async throws -> CleanupTextResult {
    switch configuration.provider {
    case .openRouter:
      try await openRouter.clean(
        text, mode: mode, configuration: configuration, apiKey: apiKey)
    case .groq:
      try await groq.clean(text, mode: mode, configuration: configuration, apiKey: apiKey)
    case .cerebras:
      try await cerebras.clean(text, mode: mode, configuration: configuration, apiKey: apiKey)
    }
  }
}

import Foundation

struct AvailableUpdate: Equatable, Sendable {
  let build: String
  let version: String
}

enum UpdateStage: Equatable, Sendable {
  case idle, checking, offering, downloading, preparing, readyToInstall, installing

  var preventsOfflineTransition: Bool {
    self == .preparing || self == .installing
  }
}

enum UpdateUserChoice: Equatable, Sendable {
  case install, later, skip
}

enum UpdateEngineEvent {
  case stage(UpdateStage)
  case feedLoaded
  case found(AvailableUpdate, userInitiated: Bool)
  case presentingOffer
  case notFound(String)
  case choice(UpdateUserChoice, AvailableUpdate)
  case restartRequested
  case cycleFinished(error: String?)
  case settingsChanged
}

/// Keeps Sparkle's UI and installer behind a small, testable application boundary.
@MainActor
protocol UpdateEngine: AnyObject {
  var onEvent: ((UpdateEngineEvent) -> Void)? { get set }
  var allowsNetwork: (() -> Bool)? { get set }
  var allowsPresentation: (() -> Bool)? { get set }
  var automaticallyChecks: Bool { get set }
  var canCheck: Bool { get }
  func start() throws
  func checkForUpdates(showProgress: Bool)
  /// Cancels the current public UI operation where supported. Background feed
  /// requests must settle before the cycle-finished event completes the transition.
  func cancelCurrentCycle()
  func settingsChanged()
  func resumeDeferredPresentation()
}

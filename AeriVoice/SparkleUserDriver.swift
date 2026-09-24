#if AERIVOICE_APP
import Foundation
import Sparkle

@MainActor
final class SparkleUserDriver: NSObject, SPUUserDriver, SPUStandardUserDriverDelegate {
  var emit: ((UpdateEngineEvent) -> Void)?
  var networkAllowed: (() -> Bool)?
  var presentationAllowed: (() -> Bool)?
  var showsCheckingProgress = true
  private var deferredPresentation: (() -> Void)?
  private let hostBundle: Bundle
  private lazy var standard = SPUStandardUserDriver(hostBundle: hostBundle, delegate: self)
  private(set) var cancelledByApp = false
  private var stage: UpdateStage = .idle
  private var cancellation: UpdateReply<Void>?
  private var choice: UpdateReply<SPUUserUpdateChoice>?
  private var acknowledgement: UpdateReply<Void>?
  private var permitted: Bool { !cancelledByApp && networkAllowed?() == true }

  init(hostBundle: Bundle) { self.hostBundle = hostBundle; super.init() }
  private func setStage(_ stage: UpdateStage) { self.stage = stage; emit?(.stage(stage)) }
  func beginCycle() { setStage(.checking) }
  func finishCycle() {
    cancellation?.invalidate(); cancellation = nil
    choice?.invalidate(); choice = nil
    acknowledgement?.invalidate(); acknowledgement = nil
    deferredPresentation = nil
    cancelledByApp = false
    showsCheckingProgress = true
    setStage(.idle)
  }

  func cancelCurrentCycle() {
    guard !stage.preventsOfflineTransition else { return }
    cancelledByApp = true
    deferredPresentation = nil
    // Dismissing native windows alone does not cancel the Sparkle operation.
    // Consume the stage's actual reply and await didFinishUpdateCycle.
    standard.dismissUpdateInstallation()
    if let acknowledgement { acknowledgement.resolve(()) }
    switch stage {
    case .checking, .downloading: cancellation?.resolve(())
    case .offering, .readyToInstall:
      if let reply = Self.offlineChoice(for: stage) { choice?.resolve(reply) }
    default: break
    }
  }

  static func offlineChoice(for stage: UpdateStage) -> SPUUserUpdateChoice? {
    switch stage {
    case .offering: return .dismiss
    case .readyToInstall: return .skip
    default: return nil
    }
  }

  private func showCancellation(_ callback: @escaping () -> Void, stage: UpdateStage,
                                show: (@escaping () -> Void) -> Void) {
    deferredPresentation = nil
    cancellation?.invalidate()
    let reply = UpdateReply<Void> { _ in callback() }
    cancellation = reply
    setStage(stage)
    guard permitted else { reply.resolve(()); return }
    show { reply.resolve(()) }
  }

  func show(_ request: SPUUpdatePermissionRequest,
                                   reply: @escaping (SUUpdatePermissionResponse) -> Void) {
    // Automatic-check consent is configured by the app, not a second modal.
    reply(SUUpdatePermissionResponse(automaticUpdateChecks: permitted, sendSystemProfile: false))
  }
  func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
    showCancellation(cancellation, stage: .checking) { cancel in
      // Automatic Settings revalidation is quiet until the offer is ready.
      // A checking window would take key focus and cancel its own request.
      if showsCheckingProgress { standard.showUserInitiatedUpdateCheck(cancellation: cancel) }
    }
  }
  func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState,
                       reply: @escaping (SPUUserUpdateChoice) -> Void) {
    cancellation?.invalidate(); cancellation = nil
    let update = AvailableUpdate(build: appcastItem.versionString, version: appcastItem.displayVersionString)
    let once = UpdateReply(reply)
    choice?.invalidate(); choice = once
    // A resumed installer no longer has a cancellable download. Keep the same
    // narrow Offline restriction as extraction until the user resolves it.
    setStage(state.stage == .installing ? .preparing : .offering)
    guard permitted else { once.resolve(.dismiss); return }
    emit?(.found(update, userInitiated: state.userInitiated))
    guard state.userInitiated else { once.resolve(.dismiss); return }
    presentOrDefer { [weak self] in
      guard let self else { return }
      self.emit?(.presentingOffer)
      self.standard.showUpdateFound(with: appcastItem, state: state) { [weak self] selected in
        guard let self else { return }
        guard self.permitted else { once.resolve(.dismiss); return }
        once.resolve(selected) {
          let userChoice: UpdateUserChoice
          switch selected {
          case .install: userChoice = .install
          case .skip: userChoice = .skip
          default: userChoice = .later
          }
          self.emit?(.choice(userChoice, update))
          // Coordinate application shutdown before Sparkle can request it.
          if selected == .install && state.stage == .installing {
            self.emit?(.restartRequested)
          }
        }
      }
    }
  }

  func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
  func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}

  private func showAcknowledgement(_ callback: @escaping () -> Void,
                                   show: @escaping (@escaping () -> Void) -> Void) {
    cancellation?.invalidate(); cancellation = nil
    choice?.invalidate(); choice = nil
    let once = UpdateReply<Void> { _ in callback() }
    acknowledgement?.invalidate(); acknowledgement = once
    guard permitted else { once.resolve(()); return }
    presentOrDefer { show { once.resolve(()) } }
  }
  func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
    showAcknowledgement(acknowledgement) { [weak self] in self?.standard.showUpdateNotFoundWithError(error, acknowledgement: $0) }
  }
  func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
    showAcknowledgement(acknowledgement) { [weak self] in self?.standard.showUpdaterError(error, acknowledgement: $0) }
  }
  func showDownloadInitiated(cancellation: @escaping () -> Void) {
    choice?.invalidate(); choice = nil
    showCancellation(cancellation, stage: .downloading) { standard.showDownloadInitiated(cancellation: $0) }
  }
  func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
    if permitted { standard.showDownloadDidReceiveExpectedContentLength(expectedContentLength) }
  }
  func showDownloadDidReceiveData(ofLength length: UInt64) {
    if permitted { standard.showDownloadDidReceiveData(ofLength: length) }
  }
  func showDownloadDidStartExtractingUpdate() {
    deferredPresentation = nil
    cancellation?.invalidate(); cancellation = nil
    setStage(.preparing)
    standard.showDownloadDidStartExtractingUpdate()
  }
  func showExtractionReceivedProgress(_ progress: Double) { standard.showExtractionReceivedProgress(progress) }
  func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
    let once = UpdateReply<SPUUserUpdateChoice> { [weak self] selected in
      if selected == .install { self?.emit?(.restartRequested) }
      reply(selected)
    }
    choice?.invalidate(); choice = once
    setStage(.readyToInstall)
    guard permitted else { once.resolve(.skip); return }
    presentOrDefer { [weak self] in
      self?.standard.showReady(toInstallAndRelaunch: { [weak self] selected in
        once.resolve(self?.permitted == true ? selected : .skip)
      })
    }
  }
  func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool,
                            retryTerminatingApplication: @escaping () -> Void) {
    deferredPresentation = nil
    choice?.invalidate(); choice = nil
    setStage(.installing)
    standard.showInstallingUpdate(withApplicationTerminated: applicationTerminated,
                                  retryTerminatingApplication: retryTerminatingApplication)
  }
  func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
    showAcknowledgement(acknowledgement) { [weak self] in self?.standard.showUpdateInstalledAndRelaunched(relaunched, acknowledgement: $0) }
  }
  private func presentOrDefer(_ render: @escaping () -> Void) {
    guard permitted else { return }
    if presentationAllowed?() == true { render() }
    else { deferredPresentation = render }
  }
  func resumeDeferredPresentation() {
    guard permitted, presentationAllowed?() == true else { return }
    let render = deferredPresentation
    deferredPresentation = nil
    render?()
  }
  func dismissUpdateInstallation() {
    deferredPresentation = nil
    standard.dismissUpdateInstallation()
  }
  func showUpdateInFocus() {
    if permitted && presentationAllowed?() == true { standard.showUpdateInFocus() }
  }
  nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }
  nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool { false }
  nonisolated func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {}
  nonisolated func standardUserDriverShouldShowVersionHistory(for appcastItem: SUAppcastItem) -> Bool { false }
}
#endif

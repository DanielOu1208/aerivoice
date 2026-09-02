import AppKit
import Combine
@preconcurrency import CoreAudio
import XCTest

@testable import AeriVoice

final class ModelTests: XCTestCase {
  func testKeychainServiceSeparatesReleaseAndDebugCredentials() {
    XCTAssertEqual(
      KeychainStore.serviceName(
        bundleIdentifier: "com.danielou.AeriVoice", namespace: .legacyRelease),
      "com.danielou.AeriVoice.credentials")
    XCTAssertEqual(
      KeychainStore.serviceName(
        bundleIdentifier: "com.danielou.AeriVoice", namespace: .releaseV2),
      "com.danielou.AeriVoice.credentials.v2")
    XCTAssertEqual(
      KeychainStore.serviceName(
        bundleIdentifier: "com.danielou.AeriVoice", namespace: .development),
      "com.danielou.AeriVoice.credentials.development")
    XCTAssertEqual(
      KeychainStore.serviceName(bundleIdentifier: nil, namespace: .releaseV2),
      "com.danielou.AeriVoice.credentials.v2")
  }

  func testCurrentKeychainNamespaceMatchesBuildConfiguration() {
    #if AERIVOICE_DISTRIBUTION
      XCTAssertEqual(CredentialNamespace.current.rawValue, "credentials.v2")
    #else
      XCTAssertEqual(CredentialNamespace.current.rawValue, "credentials.development")
    #endif
  }

  func testCleanupModelCatalogAndCapabilities() {
    XCTAssertEqual(
      CleanupModel.allCases,
      [
        .gemini37Flash, .gptOSS120BCerebras, .gemini35FlashLite, .gpt56LunaFast,
        .qwen38_27BGroq,
      ])
    XCTAssertEqual(CleanupModel.defaultModel, .gemini35FlashLite)
    XCTAssertEqual(CleanupProvider.openRouter.defaultModel, .gemini35FlashLite)
    XCTAssertEqual(CleanupProvider.groq.defaultModel, .qwen38_27BGroq)
    XCTAssertEqual(CleanupProvider.groq.models, [.qwen38_27BGroq])
    XCTAssertEqual(
      CleanupModel.gemini37Flash.supportedReasoningEfforts, [.low, .medium, .high])
    XCTAssertEqual(
      CleanupModel.gptOSS120BCerebras.supportedReasoningEfforts, [.low, .medium, .high])
    XCTAssertEqual(
      CleanupModel.gemini35FlashLite.supportedReasoningEfforts,
      [.minimal, .low, .medium, .high])
    XCTAssertEqual(CleanupModel.gemini35FlashLite.defaultReasoningEffort, .minimal)
    XCTAssertEqual(
      CleanupModel.gpt56LunaFast.supportedReasoningEfforts,
      [.none, .low, .medium, .high, .xhigh, .max])
    XCTAssertEqual(CleanupModel.qwen38_27BGroq.supportedReasoningEfforts, [.none, .low])
    XCTAssertEqual(CleanupModel.qwen38_27BGroq.defaultReasoningEffort, .none)
    XCTAssertEqual(CleanupModel.gptOSS120BCerebras.providerRoute.only, ["cerebras/fp16"])
    XCTAssertTrue(CleanupModel.gptOSS120BCerebras.providerRoute.requiresZeroDataRetention)
    XCTAssertEqual(CleanupModel.gpt56LunaFast.providerRoute.only, ["openai/fast"])
    XCTAssertFalse(CleanupModel.gpt56LunaFast.providerRoute.requiresZeroDataRetention)
    XCTAssertFalse(CleanupProvider.openRouter.isExperimental)
    XCTAssertTrue(CleanupProvider.groq.isExperimental)
  }

  func testOnboardingReadinessRoutesToFirstIncompleteStep() {
    XCTAssertEqual(
      OnboardingReadiness(
        hasSonioxCredential: false, hasOpenRouterCredential: false,
        hasPermissions: false, hasShortcut: false
      ).recommendedStep,
      .providers)
    XCTAssertEqual(
      OnboardingReadiness(
        hasSonioxCredential: true, hasOpenRouterCredential: true,
        hasPermissions: false, hasShortcut: false
      ).recommendedStep,
      .permissions)
    XCTAssertEqual(
      OnboardingReadiness(
        hasSonioxCredential: true, hasOpenRouterCredential: true,
        hasPermissions: true, hasShortcut: false
      ).recommendedStep,
      .shortcut)
  }

  func testOnboardingReadinessGatesEachStepIndependently() {
    let ready = OnboardingReadiness(
      hasSonioxCredential: true, hasOpenRouterCredential: true,
      hasPermissions: true, hasShortcut: true)
    for step in OnboardingStep.allCases {
      XCTAssertTrue(ready.canAdvance(from: step))
    }

    let missingShortcut = OnboardingReadiness(
      hasSonioxCredential: true, hasOpenRouterCredential: true,
      hasPermissions: true, hasShortcut: false)
    XCTAssertTrue(missingShortcut.canAdvance(from: .providers))
    XCTAssertTrue(missingShortcut.canAdvance(from: .permissions))
    XCTAssertFalse(missingShortcut.canAdvance(from: .shortcut))
  }

  func testDeniedMicrophonePermissionRoutesToSystemSettings() {
    XCTAssertEqual(MicrophonePermissionAction(status: .notDetermined), .request)
    XCTAssertEqual(MicrophonePermissionAction(status: .denied), .openSettings)
    XCTAssertEqual(MicrophonePermissionAction(status: .restricted), .openSettings)
    XCTAssertEqual(MicrophonePermissionAction(status: .authorized), .none)
  }

  @MainActor
  func testShortcutActivationModeDefaultsToHybridAndPersistsToggle() {
    let suite = "AeriVoiceTests.ShortcutActivationMode.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.removePersistentDomain(forName: suite)

    let preferences = AppPreferences(defaults: defaults)
    XCTAssertEqual(preferences.shortcutActivationMode, .hybrid)

    preferences.shortcutActivationMode = .toggle
    XCTAssertEqual(defaults.string(forKey: "shortcutActivationMode"), "toggle")
    XCTAssertEqual(AppPreferences(defaults: defaults).shortcutActivationMode, .toggle)
  }

  @MainActor
  func testUnknownShortcutActivationModeFallsBackToHybrid() {
    let suite = "AeriVoiceTests.UnknownShortcutActivationMode.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.removePersistentDomain(forName: suite)
    defaults.set("removed-mode", forKey: "shortcutActivationMode")

    XCTAssertEqual(AppPreferences(defaults: defaults).shortcutActivationMode, .hybrid)
  }

  @MainActor
  func testLaunchAtLoginPersistsAcceptedServiceState() {
    let suite = "AeriVoiceTests.LaunchAtLogin.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.removePersistentDomain(forName: suite)
    let loginItems = LoginItemManagerStub()
    let preferences = AppPreferences(defaults: defaults, loginItemManager: loginItems)

    XCTAssertTrue(preferences.setLaunchAtLogin(true))
    XCTAssertTrue(preferences.launchAtLogin)

    let restored = AppPreferences(defaults: defaults, loginItemManager: loginItems)
    XCTAssertTrue(restored.launchAtLogin)
  }

  @MainActor
  func testLaunchAtLoginFailureRestoresActualServiceState() {
    let suite = "AeriVoiceTests.LaunchAtLoginFailure.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.removePersistentDomain(forName: suite)
    let loginItems = LoginItemManagerStub()
    loginItems.shouldFail = true
    let preferences = AppPreferences(defaults: defaults, loginItemManager: loginItems)

    XCTAssertFalse(preferences.setLaunchAtLogin(true))
    XCTAssertFalse(preferences.launchAtLogin)
    XCTAssertFalse(defaults.bool(forKey: "launchAtLogin"))
  }

  @MainActor
  func testDisablingLaunchAtLoginUnregistersPendingApproval() {
    let suite = "AeriVoiceTests.LaunchAtLoginApproval.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.removePersistentDomain(forName: suite)
    let loginItems = LoginItemManagerStub(status: .requiresApproval)
    let preferences = AppPreferences(defaults: defaults, loginItemManager: loginItems)

    XCTAssertTrue(preferences.setLaunchAtLogin(false))
    XCTAssertEqual(loginItems.status, .disabled)
    XCTAssertEqual(loginItems.updateRequests, [false])
    XCTAssertFalse(preferences.launchAtLogin)
  }

  @MainActor
  func testCleanupPreferencesRememberModelAndReasoningPerProvider() {
    let suite = "AeriVoiceTests.ProviderPreferences.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.removePersistentDomain(forName: suite)
    let preferences = AppPreferences(defaults: defaults)

    preferences.cleanupModel = .gpt56LunaFast
    preferences.cleanupReasoningEffort = .xhigh
    preferences.cleanupProvider = .groq
    XCTAssertEqual(preferences.cleanupModel, .qwen38_27BGroq)
    XCTAssertEqual(preferences.cleanupReasoningEffort, .none)
    preferences.cleanupReasoningEffort = .low

    preferences.cleanupProvider = .openRouter
    XCTAssertEqual(preferences.cleanupModel, .gpt56LunaFast)
    XCTAssertEqual(preferences.cleanupReasoningEffort, .xhigh)

    let restored = AppPreferences(defaults: defaults)
    XCTAssertEqual(restored.cleanupProvider, .openRouter)
    XCTAssertEqual(restored.cleanupModel, .gpt56LunaFast)
    restored.cleanupProvider = .groq
    XCTAssertEqual(restored.cleanupModel, .qwen38_27BGroq)
    XCTAssertEqual(restored.cleanupReasoningEffort, .low)
  }

  @MainActor
  func testCleanupSelectionsPublishOneCanonicalChangeAndPersistLegacyKeys() {
    let suite = "AeriVoiceTests.CanonicalCleanupPreferences.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.removePersistentDomain(forName: suite)
    let preferences = AppPreferences(defaults: defaults)
    var changeCount = 0
    let observation = preferences.objectWillChange.sink { changeCount += 1 }

    preferences.cleanupProvider = .groq
    XCTAssertEqual(changeCount, 1)
    XCTAssertEqual(preferences.cleanupModel, .qwen38_27BGroq)

    changeCount = 0
    preferences.cleanupModel = .gemini35FlashLite
    XCTAssertEqual(changeCount, 1)
    XCTAssertEqual(preferences.cleanupProvider, .openRouter)
    XCTAssertEqual(defaults.string(forKey: "cleanupProvider"), CleanupProvider.openRouter.rawValue)
    XCTAssertEqual(defaults.string(forKey: "cleanupModel"), CleanupModel.gemini35FlashLite.rawValue)

    let restored = AppPreferences(defaults: defaults)
    XCTAssertEqual(restored.cleanupProvider, .openRouter)
    XCTAssertEqual(restored.cleanupModel, .gemini35FlashLite)
    withExtendedLifetime(observation) {}
  }

  @MainActor
  func testCleanupPreferencesRememberReasoningPerModel() {
    let suite = "AeriVoiceTests.Preferences.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.removePersistentDomain(forName: suite)
    let preferences = AppPreferences(defaults: defaults)

    XCTAssertEqual(preferences.cleanupModel, .gemini35FlashLite)
    XCTAssertEqual(preferences.cleanupReasoningEffort, .minimal)
    preferences.cleanupReasoningEffort = .high
    preferences.cleanupModel = .gemini37Flash
    XCTAssertEqual(preferences.cleanupReasoningEffort, .low)
    preferences.cleanupReasoningEffort = .medium
    preferences.cleanupModel = .gemini35FlashLite
    XCTAssertEqual(preferences.cleanupReasoningEffort, .high)
    preferences.cleanupModel = .gemini37Flash
    XCTAssertEqual(preferences.cleanupReasoningEffort, .medium)

    preferences.cleanupModel = .gemini35FlashLite
    let restored = AppPreferences(defaults: defaults)
    XCTAssertEqual(restored.cleanupModel, .gemini35FlashLite)
    XCTAssertEqual(restored.cleanupReasoningEffort, .high)
  }

  @MainActor
  func testExistingCleanupSelectionIsPreservedWhenDefaultsChange() throws {
    let suite = "AeriVoiceTests.ExistingCleanupSelection.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.removePersistentDomain(forName: suite)
    defaults.set(CleanupProvider.openRouter.rawValue, forKey: "cleanupProvider")
    defaults.set(CleanupModel.gemini37Flash.rawValue, forKey: "cleanupModel")
    defaults.set(
      try JSONEncoder().encode([
        CleanupModel.gemini37Flash.rawValue: CleanupReasoningEffort.high.rawValue
      ]),
      forKey: "cleanupReasoningEfforts")

    let preferences = AppPreferences(defaults: defaults)

    XCTAssertEqual(preferences.cleanupProvider, .openRouter)
    XCTAssertEqual(preferences.cleanupModel, .gemini37Flash)
    XCTAssertEqual(preferences.cleanupReasoningEffort, .high)
  }

  @MainActor
  func testCleanupPreferencesRecoverUnknownOrUnsupportedValues() throws {
    let suite = "AeriVoiceTests.Preferences.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.removePersistentDomain(forName: suite)
    defaults.set("removed-model", forKey: "cleanupModel")
    defaults.set(
      try JSONEncoder().encode([CleanupModel.gemini37Flash.rawValue: "max"]),
      forKey: "cleanupReasoningEfforts")

    let preferences = AppPreferences(defaults: defaults)

    XCTAssertEqual(preferences.cleanupModel, .gemini35FlashLite)
    XCTAssertEqual(preferences.cleanupReasoningEffort, .minimal)
    XCTAssertEqual(
      CleanupConfiguration(model: .gptOSS120BCerebras, reasoningEffort: .max).reasoningEffort,
      .low)
    XCTAssertEqual(
      CleanupConfiguration(model: .qwen38_27BGroq, reasoningEffort: .medium).reasoningEffort,
      .none)
  }

  func testVocabularyTrimsDeduplicatesAndPreservesFirstSpelling() {
    XCTAssertEqual(
      VocabularyNormalizer.normalize("  Soniox  \nsoniox\n Gemini\n\nAeri"),
      ["Soniox", "Gemini", "Aeri"])
  }

  func testVocabularyStopsBeforeLimit() {
    XCTAssertEqual(VocabularyNormalizer.normalize("abc\ndef", limit: 5), ["abc"])
  }

  func testVocabularyParsingPreservesTermsBeyondTransmissionLimit() {
    let raw = "alpha\nbeta\ngamma"

    XCTAssertEqual(VocabularyNormalizer.parse(raw), ["alpha", "beta", "gamma"])
    XCTAssertEqual(VocabularyNormalizer.normalize(raw, limit: 10), ["alpha", "beta"])
  }

  func testRemovingFromOversizedLegacyVocabularyPreservesLaterTerms() {
    let oversizedTerm = String(repeating: "a", count: 10_000)
    XCTAssertEqual(
      VocabularyNormalizer.removing(oversizedTerm, from: "\(oversizedTerm)\nbeta\ngamma"),
      ["beta", "gamma"])
  }

  func testAddingToOversizedLegacyVocabularyDoesNotRewriteIt() {
    XCTAssertEqual(
      VocabularyNormalizer.adding("delta", to: "alpha\nbeta\ngamma", limit: 10),
      .limitExceeded)
  }

  func testVocabularyLimitCountsUnicodeBytes() {
    XCTAssertEqual(VocabularyNormalizer.normalize("é\nß\n東京", limit: 5), ["é", "ß"])
    XCTAssertEqual(
      VocabularyNormalizer.adding("ß", to: "é", limit: 5), .added(["é", "ß"]))
  }

  func testVocabularyAddsAndRemovesTermsWithoutChangingStoredFormat() {
    XCTAssertEqual(
      VocabularyNormalizer.adding("  Daniel Ou  ", to: "Soniox\nAeriVoice"),
      .added(["Soniox", "AeriVoice", "Daniel Ou"]))
    XCTAssertEqual(
      VocabularyNormalizer.removing("aerivoice", from: "Soniox\nAeriVoice\nDaniel Ou"),
      ["Soniox", "Daniel Ou"])
  }

  func testVocabularyRejectsDuplicateAndOversizedTerms() {
    XCTAssertEqual(VocabularyNormalizer.adding("soniox", to: "Soniox"), .duplicate)
    XCTAssertEqual(VocabularyNormalizer.adding("Daniel\nOu", to: ""), .multipleTerms)
    XCTAssertEqual(VocabularyNormalizer.adding("def", to: "abc", limit: 5), .limitExceeded)
    XCTAssertEqual(VocabularyNormalizer.adding("é", to: "", limit: 2), .added(["é"]))
    XCTAssertEqual(VocabularyNormalizer.adding("a", to: "é", limit: 3), .limitExceeded)
  }

  func testTranscriptAssemblerReplacesProvisionalTail() {
    var assembler = TranscriptAssembler()
    XCTAssertEqual(
      assembler.consume([("Hello", true), (" wor", false)]),
      TranscriptSnapshot(confirmed: "Hello", provisional: " wor"))
    XCTAssertEqual(
      assembler.consume([(" world", true), ("!", false)]),
      TranscriptSnapshot(confirmed: "Hello world", provisional: "!"))
  }

  func testTranscriptAssemblerIgnoresFinToken() {
    var assembler = TranscriptAssembler()
    XCTAssertEqual(assembler.consume([("Hi", true), ("<fin>", true)]).displayText, "Hi")
  }

  func testSonioxResponseDecodesAudioProgressAndFinalText() throws {
    let data =
      #"{"tokens":[{"text":"Hello","is_final":true},{"text":"<fin>","is_final":true}],"final_audio_proc_ms":760,"total_audio_proc_ms":880}"#
      .data(
        using: .utf8)!
    let response = try JSONDecoder().decode(SonioxResponse.self, from: data)

    XCTAssertEqual(response.finalAudioProcessedMS, 760)
    XCTAssertEqual(response.totalAudioProcessedMS, 880)
    XCTAssertTrue(response.hasFinalText)
  }

  func testSonioxWhitespaceAndFinishTokensAreNotFinalText() throws {
    let data =
      #"{"tokens":[{"text":"  \n","is_final":true},{"text":"<fin>","is_final":true}],"final_audio_proc_ms":100,"total_audio_proc_ms":100}"#
      .data(
        using: .utf8)!
    let response = try JSONDecoder().decode(SonioxResponse.self, from: data)

    XCTAssertFalse(response.hasFinalText)
  }

  func testTranscriptTailKeepsNewestConfirmedAndProvisionalText() {
    let tail = TranscriptTail.make(
      from: TranscriptSnapshot(confirmed: "0123456789", provisional: "abc"), limit: 7)
    XCTAssertEqual(tail, TranscriptSnapshot(confirmed: "6789", provisional: "abc"))
  }

  func testModifierOnlyShortcutDoesNotCollideWithPhysicalA() throws {
    let modifierOnly = ShortcutDefinition(
      keyCode: 0, modifiers: UInt(NSEvent.ModifierFlags.command.rawValue), displayName: "⌘",
      isModifierOnly: true)
    let physicalA = ShortcutDefinition(keyCode: 0, modifiers: 0, displayName: "A")
    XCTAssertNotEqual(modifierOnly, physicalA)
    XCTAssertEqual(
      try JSONDecoder().decode(
        ShortcutDefinition.self, from: JSONEncoder().encode(modifierOnly)), modifierOnly)
  }

  func testModifierOnlyShortcutReportsPressAndFirstRelease() {
    var latch = ModifierShortcutLatch()
    let option = UInt64(NSEvent.ModifierFlags.option.rawValue)
    let command = UInt64(NSEvent.ModifierFlags.command.rawValue)
    let required = option | command

    XCTAssertEqual(latch.flagsChanged(current: option, required: required), .passThrough)
    XCTAssertEqual(latch.flagsChanged(current: required, required: required), .press)
    XCTAssertEqual(latch.flagsChanged(current: option, required: required), .release)
    XCTAssertEqual(latch.flagsChanged(current: 0, required: required), .consume)
    XCTAssertFalse(latch.isActive)
  }

  func testModifierOnlyShortcutCanTriggerAgainAfterFullRelease() {
    var latch = ModifierShortcutLatch()
    let required = UInt64(
      NSEvent.ModifierFlags.option.union(.command).rawValue)

    XCTAssertEqual(latch.flagsChanged(current: required, required: required), .press)
    XCTAssertEqual(latch.flagsChanged(current: 0, required: required), .release)
    XCTAssertEqual(latch.flagsChanged(current: required, required: required), .press)
  }

  func testModifierOnlyShortcutDoesNotRetriggerBeforeFullRelease() {
    var latch = ModifierShortcutLatch()
    let option = UInt64(NSEvent.ModifierFlags.option.rawValue)
    let required = UInt64(NSEvent.ModifierFlags.option.union(.command).rawValue)

    XCTAssertEqual(latch.flagsChanged(current: required, required: required), .press)
    XCTAssertEqual(latch.flagsChanged(current: option, required: required), .release)
    XCTAssertEqual(latch.flagsChanged(current: required, required: required), .consume)
    XCTAssertEqual(latch.flagsChanged(current: 0, required: required), .consume)
    XCTAssertEqual(latch.flagsChanged(current: required, required: required), .press)
  }

  func testShortcutPressTrackerUsesInclusiveHybridHoldThreshold() {
    let start: CGEventTimestamp = 1_000_000_000
    var tracker = ShortcutPressTracker()

    tracker.press(at: start, finishesOnRelease: true)
    XCTAssertFalse(
      tracker.release(at: start + ShortcutPressTracker.holdThreshold - 1))

    tracker.press(at: start, finishesOnRelease: true)
    XCTAssertTrue(tracker.release(at: start + ShortcutPressTracker.holdThreshold))
  }

  func testShortcutPressTrackerIgnoresReleaseWhenNotArmed() {
    var tracker = ShortcutPressTracker()
    tracker.press(at: 0, finishesOnRelease: false)

    XCTAssertFalse(tracker.release(at: ShortcutPressTracker.holdThreshold * 2))
    XCTAssertFalse(tracker.isPressed)
    XCTAssertFalse(tracker.release(at: ShortcutPressTracker.holdThreshold * 3))
  }

  func testShortcutPressTrackerResetDisarmsPendingRelease() {
    var tracker = ShortcutPressTracker()
    tracker.press(at: 0, finishesOnRelease: true)
    tracker.reset()

    XCTAssertFalse(tracker.release(at: ShortcutPressTracker.holdThreshold))
  }

  func testBuiltInNotchGeometry() {
    let geometry = NotchGeometry.calculate(
      frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
      safeAreaTop: 38,
      auxiliaryLeft: CGRect(x: 0, y: 944, width: 646, height: 38),
      auxiliaryRight: CGRect(x: 866, y: 944, width: 646, height: 38)
    )
    XCTAssertEqual(geometry.physicalNotchWidth, 220)
    XCTAssertEqual(geometry.frame, CGRect(x: 576, y: 910, width: 360, height: 72))
    XCTAssertFalse(geometry.isExternalFallback)
  }

  func testExternalFallbackGeometry() {
    let geometry = NotchGeometry.calculate(
      frame: CGRect(x: 100, y: 50, width: 1920, height: 1080), safeAreaTop: 0, auxiliaryLeft: nil,
      auxiliaryRight: nil)
    XCTAssertEqual(geometry.frame, CGRect(x: 880, y: 1086, width: 360, height: 44))
    XCTAssertTrue(geometry.isExternalFallback)
  }

  func testNotchTransitionTimingsAndCurves() {
    let opening = NotchTransitionPlan(isOpening: true, reducesMotion: false)
    let closing = NotchTransitionPlan(isOpening: false, reducesMotion: false)

    XCTAssertEqual(opening.duration, 0.26, accuracy: 0.001)
    XCTAssertEqual(opening.curve, .spring)
    XCTAssertEqual(closing.duration, 0.16, accuracy: 0.001)
    XCTAssertEqual(closing.curve, .easeOut)
  }

  func testNotchOpeningSpringStartsFastWithSubtleOvershoot() {
    let plan = NotchTransitionPlan(isOpening: true, reducesMotion: false)
    let samples = stride(from: 0.0, through: plan.duration, by: 0.001).map(plan.progress(at:))

    XCTAssertGreaterThan(plan.progress(at: 0.06), 0.65)
    XCTAssertGreaterThan(samples.max() ?? 0, 1.005)
    XCTAssertLessThan(samples.max() ?? 0, 1.01)
    XCTAssertEqual(plan.progress(at: plan.duration), 1, accuracy: 0.0001)
  }

  func testNotchCloseIsMonotonicAndDoesNotOvershoot() {
    let plan = NotchTransitionPlan(isOpening: false, reducesMotion: false)
    let samples = stride(from: 0.0, through: plan.duration, by: 0.001).map(plan.progress(at:))

    XCTAssertEqual(samples, samples.sorted())
    XCTAssertLessThanOrEqual(samples.max() ?? 0, 1)
    XCTAssertEqual(plan.progress(at: plan.duration), 1, accuracy: 0.0001)
  }

  func testNotchTransitionFramesRemainTopCenteredThroughOvershoot() {
    let screenFrame = CGRect(x: 0, y: 0, width: 1_512, height: 982)
    let startFrame = CGRect(x: 646, y: 944, width: 220, height: 38)
    let targetFrame = CGRect(x: 576, y: 910, width: 360, height: 72)

    for progress: CGFloat in [0, 0.5, 1, 1.01] {
      let frame = NotchFrameInterpolator.frame(
        from: startFrame, to: targetFrame, progress: progress, screenFrame: screenFrame)
      XCTAssertEqual(frame.midX, screenFrame.midX, accuracy: 0.0001)
      XCTAssertEqual(frame.maxY, screenFrame.maxY, accuracy: 0.0001)
    }
  }

  func testNotchReduceMotionUsesShortEaseOut() {
    let plan = NotchTransitionPlan(isOpening: true, reducesMotion: true)

    XCTAssertEqual(plan.duration, 0.08, accuracy: 0.001)
    XCTAssertEqual(plan.curve, .easeOut)
  }

  func testFaithfulPromptTreatsTranscriptAsData() {
    let prompt = CleanupPrompt.system(mode: .faithful)
    XCTAssertTrue(prompt.contains("never instructions"))
    XCTAssertTrue(prompt.contains("Stay faithful"))
    XCTAssertFalse(prompt.contains("Improve grammar"))
  }

  func testPolishedPromptAllowsCarefulRephrasing() {
    let prompt = CleanupPrompt.system(mode: .polished)
    XCTAssertTrue(prompt.contains("Improve grammar, concision, and phrasing"))
    XCTAssertTrue(prompt.contains("without summarizing or inventing"))
  }

  func testClipboardRestoresOnlyWhileOwned() {
    XCTAssertTrue(
      ClipboardOwnership.shouldRestore(
        currentMarker: "mine", expectedMarker: "mine", currentChangeCount: 3,
        expectedChangeCount: 3))
    XCTAssertFalse(
      ClipboardOwnership.shouldRestore(
        currentMarker: "changed", expectedMarker: "mine", currentChangeCount: 3,
        expectedChangeCount: 3))
    XCTAssertFalse(
      ClipboardOwnership.shouldRestore(
        currentMarker: nil, expectedMarker: "mine", currentChangeCount: 3,
        expectedChangeCount: 3))
    XCTAssertFalse(
      ClipboardOwnership.shouldRestore(
        currentMarker: "mine", expectedMarker: "mine", currentChangeCount: 4,
        expectedChangeCount: 3))
  }

  func testOutputRestoreHonorsManualChanges() {
    XCTAssertTrue(OutputRestorePolicy.shouldRestore(current: 0, applied: 0))
    XCTAssertFalse(OutputRestorePolicy.shouldRestore(current: 0.25, applied: 0))
  }

  func testCoreAudioDeviceUIDRoundTrip() throws {
    let backend = CoreAudioOutputBackend()
    let device = try XCTUnwrap(backend.defaultOutputDevice())
    let uid = try XCTUnwrap(backend.deviceUID(device))

    XCTAssertEqual(backend.deviceID(forUID: uid), device)
  }

  func testOutputMuteRestoresMuteFlagImmediately() {
    withMuteFixture { controller, backend, defaults in
      XCTAssertTrue(controller.mute())
      XCTAssertEqual(backend.muteValue, 1)

      controller.restore()

      XCTAssertEqual(backend.muteValue, 0)
      XCTAssertNil(defaults.data(forKey: "outputRestoreRecords"))
    }
  }

  func testOutputMutePersistsRecoveryRecordBeforeChangingAudio() {
    withMuteFixture { controller, backend, defaults in
      backend.beforeMuteWrite = {
        XCTAssertNotNil(defaults.data(forKey: "outputRestoreRecords"))
      }

      XCTAssertTrue(controller.mute())
    }
  }

  func testOutputMuteDiscardsRecordAfterConfirmedFailedWrite() {
    let suite = "AeriVoiceTests.OutputMute.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    defer { defaults.removePersistentDomain(forName: suite) }
    let backend = FakeOutputAudioBackend(muteValue: 0, volumeValue: nil)
    backend.failMuteWrites = 1
    let controller = OutputMuteController(defaults: defaults, backend: backend)

    XCTAssertFalse(controller.mute())
    XCTAssertEqual(backend.muteValue, 0)
    XCTAssertNil(defaults.data(forKey: "outputRestoreRecords"))
  }

  func testOutputMuteRetriesTransientRestoreFailure() {
    withMuteFixture { controller, backend, defaults in
      XCTAssertTrue(controller.mute())
      backend.failUnmuteWrites = 1

      controller.restore()
      XCTAssertEqual(backend.muteValue, 1)
      XCTAssertNotNil(defaults.data(forKey: "outputRestoreRecords"))

      Thread.sleep(forTimeInterval: 0.12)
      XCTAssertEqual(backend.muteValue, 0)
      XCTAssertNil(defaults.data(forKey: "outputRestoreRecords"))
    }
  }

  func testStoppedObservationCannotRemuteOutput() {
    withMuteFixture { controller, backend, _ in
      XCTAssertTrue(controller.mute())
      controller.restore()
      XCTAssertEqual(backend.muteValue, 0)

      backend.emitLastDeviceChange()

      XCTAssertEqual(backend.muteValue, 0)
    }
  }

  func testOutputMuteRecoversPersistedStateOnNextLaunch() {
    let suite = "AeriVoiceTests.OutputMute.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    defer { defaults.removePersistentDomain(forName: suite) }
    let backend = FakeOutputAudioBackend()
    var controller: OutputMuteController? = OutputMuteController(
      defaults: defaults, backend: backend)
    XCTAssertTrue(controller?.mute() == true)
    XCTAssertEqual(backend.muteValue, 1)
    XCTAssertNotNil(defaults.data(forKey: "outputRestoreRecords"))

    controller = nil
    _ = OutputMuteController(defaults: defaults, backend: backend)

    XCTAssertEqual(backend.muteValue, 0)
    XCTAssertNil(defaults.data(forKey: "outputRestoreRecords"))
  }

  func testOutputMuteResolvesPersistedUIDInsteadOfReusingObjectID() throws {
    let suite = "AeriVoiceTests.OutputMute.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    defer { defaults.removePersistentDomain(forName: suite) }
    let record = OutputRestoreRecord(
      deviceID: 42, deviceUID: "fake-output", element: kAudioObjectPropertyElementMain,
      usedMute: true, originalValue: 0, appliedValue: 1)
    defaults.set(try JSONEncoder().encode([record]), forKey: "outputRestoreRecords")
    let backend = FakeOutputAudioBackend(muteValue: 1)
    backend.resolvedDeviceID = 77

    _ = OutputMuteController(defaults: defaults, backend: backend)

    XCTAssertEqual(backend.lastMuteWriteDeviceID, 77)
    XCTAssertEqual(backend.muteValue, 0)
  }

  func testOutputMuteRecoversWhenUnavailableDeviceReturns() {
    let suite = "AeriVoiceTests.OutputMute.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    defer { defaults.removePersistentDomain(forName: suite) }
    let record = OutputRestoreRecord(
      deviceID: 42, deviceUID: "fake-output", element: kAudioObjectPropertyElementMain,
      usedMute: true,
      originalValue: 0, appliedValue: 1)
    defaults.set(try! JSONEncoder().encode([record]), forKey: "outputRestoreRecords")
    let backend = FakeOutputAudioBackend(muteValue: nil)
    let controller = OutputMuteController(defaults: defaults, backend: backend)

    withExtendedLifetime(controller) {
      Thread.sleep(forTimeInterval: 1.5)
      XCTAssertNotNil(defaults.data(forKey: "outputRestoreRecords"))
      backend.muteValue = 1
      backend.emitLastDeviceChange()

      XCTAssertEqual(backend.muteValue, 0)
      XCTAssertNil(defaults.data(forKey: "outputRestoreRecords"))
    }
  }

  func testOutputMutePreservesManualVolumeChange() {
    let suite = "AeriVoiceTests.OutputMute.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    defer { defaults.removePersistentDomain(forName: suite) }
    let backend = FakeOutputAudioBackend(muteValue: nil, volumeValue: 0.65)
    let controller = OutputMuteController(defaults: defaults, backend: backend)
    XCTAssertTrue(controller.mute())
    XCTAssertEqual(backend.volumeValue, 0)
    backend.volumeValue = 0.25

    controller.restore()

    XCTAssertEqual(backend.volumeValue, 0.25)
    XCTAssertNil(defaults.data(forKey: "outputRestoreRecords"))
  }

  private func withMuteFixture(
    _ body: (OutputMuteController, FakeOutputAudioBackend, UserDefaults) -> Void
  ) {
    let suite = "AeriVoiceTests.OutputMute.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    defer { defaults.removePersistentDomain(forName: suite) }
    let backend = FakeOutputAudioBackend()
    let controller = OutputMuteController(defaults: defaults, backend: backend)
    body(controller, backend, defaults)
  }
}

@MainActor
private final class LoginItemManagerStub: LoginItemManaging {
  var status: LoginItemStatus
  var shouldFail = false
  var updateRequests: [Bool] = []

  init(status: LoginItemStatus = .disabled) {
    self.status = status
  }

  func setEnabled(_ enabled: Bool) throws {
    updateRequests.append(enabled)
    if shouldFail { throw LoginItemManagerError.rejected }
    status = enabled ? .enabled : .disabled
  }
}

private enum LoginItemManagerError: Error {
  case rejected
}

private final class FakeOutputAudioBackend: OutputAudioBackend, @unchecked Sendable {
  private let lock = NSLock()
  private var storedMuteValue: UInt32?
  private var storedVolumeValue: Float32?
  private var storedFailUnmuteWrites = 0
  private var storedFailMuteWrites = 0
  private var storedResolvedDeviceID: AudioDeviceID? = 42
  private var storedLastMuteWriteDeviceID: AudioDeviceID?
  private var lastObservation: (DispatchQueue, @Sendable () -> Void)?
  var beforeMuteWrite: (() -> Void)?

  init(muteValue: UInt32? = 0, volumeValue: Float32? = 0.65) {
    storedMuteValue = muteValue
    storedVolumeValue = volumeValue
  }

  var muteValue: UInt32? {
    get { locked { storedMuteValue } }
    set { locked { storedMuteValue = newValue } }
  }

  var volumeValue: Float32? {
    get { locked { storedVolumeValue } }
    set { locked { storedVolumeValue = newValue } }
  }

  var failUnmuteWrites: Int {
    get { locked { storedFailUnmuteWrites } }
    set { locked { storedFailUnmuteWrites = newValue } }
  }

  var failMuteWrites: Int {
    get { locked { storedFailMuteWrites } }
    set { locked { storedFailMuteWrites = newValue } }
  }

  var resolvedDeviceID: AudioDeviceID? {
    get { locked { storedResolvedDeviceID } }
    set { locked { storedResolvedDeviceID = newValue } }
  }

  var lastMuteWriteDeviceID: AudioDeviceID? {
    locked { storedLastMuteWriteDeviceID }
  }

  func defaultOutputDevice() -> AudioDeviceID? { 42 }

  func deviceUID(_ device: AudioDeviceID) -> String? { "fake-output" }

  func deviceID(forUID uid: String) -> AudioDeviceID? {
    uid == "fake-output" ? resolvedDeviceID : nil
  }

  func readVolume(_ device: AudioDeviceID, element: AudioObjectPropertyElement) -> Float32? {
    volumeValue
  }

  func readMute(_ device: AudioDeviceID, element: AudioObjectPropertyElement) -> UInt32? {
    muteValue
  }

  func setVolume(
    _ device: AudioDeviceID, element: AudioObjectPropertyElement, value: Float32
  ) -> Bool {
    locked {
      guard storedVolumeValue != nil else { return false }
      storedVolumeValue = value
      return true
    }
  }

  func setMute(
    _ device: AudioDeviceID, element: AudioObjectPropertyElement, value: UInt32
  ) -> Bool {
    beforeMuteWrite?()
    return locked {
      guard storedMuteValue != nil else { return false }
      storedLastMuteWriteDeviceID = device
      if value == 1, storedFailMuteWrites > 0 {
        storedFailMuteWrites -= 1
        return false
      }
      if value == 0, storedFailUnmuteWrites > 0 {
        storedFailUnmuteWrites -= 1
        return false
      }
      storedMuteValue = value
      return true
    }
  }

  func observeOutputDeviceChanges(
    on queue: DispatchQueue, handler: @escaping @Sendable () -> Void
  ) -> OutputDeviceObservation? {
    locked { lastObservation = (queue, handler) }
    return OutputDeviceObservation {}
  }

  func emitLastDeviceChange() {
    guard let observation = locked({ lastObservation }) else { return }
    observation.0.sync { observation.1() }
  }

  private func locked<T>(_ body: () -> T) -> T {
    lock.lock()
    defer { lock.unlock() }
    return body()
  }
}

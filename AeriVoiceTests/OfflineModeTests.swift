import Foundation
import XCTest

@testable import AeriVoice

@MainActor
final class OfflineModeTests: XCTestCase {
  func testOfflinePersistsWithoutReplacingOnlineSelections() {
    let suite = "AeriVoiceTests.Offline.\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let preferences = AppPreferences(defaults: defaults)
    preferences.onTranscriptionProviderChange = {}
    preferences.transcriptionProvider = .meta
    preferences.cleanupProvider = .groq
    preferences.localTranscriptionModel = .apple
    preferences.appleSpeechLocale = "fr-FR"
    let cleanup = preferences.cleanupConfiguration
    preferences.setOfflineMode(true)
    let restored = AppPreferences(defaults: defaults)
    restored.onTranscriptionProviderChange = {}
    XCTAssertTrue(restored.offlineMode)
    XCTAssertEqual(restored.transcriptionProvider, .meta)
    XCTAssertEqual(restored.effectiveTranscriptionProvider, .local)
    XCTAssertEqual(restored.transcriptionConfiguration.localModel, .apple)
    XCTAssertEqual(restored.transcriptionConfiguration.appleLocaleIdentifier, "fr-FR")
    XCTAssertEqual(restored.cleanupConfiguration, cleanup)
    restored.setOfflineMode(false)
    XCTAssertEqual(restored.effectiveTranscriptionProvider, .meta)
    XCTAssertEqual(restored.cleanupConfiguration, cleanup)
  }

  func testLegacyLocalSelectionRemainsNemotronAndOfflineIsOptIn() {
    let suite = "AeriVoiceTests.Offline.\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set("local", forKey: "transcriptionProvider")
    let preferences = AppPreferences(defaults: defaults)
    XCTAssertEqual(preferences.localTranscriptionModel, .nemotron)
    XCTAssertFalse(preferences.offlineMode)
  }

  func testOfflineReadinessNeedsNoCloudKeysButStillNeedsLocalAssets() {
    let suite = "AeriVoiceTests.Offline.\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let preferences = AppPreferences(defaults: defaults)
    preferences.onTranscriptionProviderChange = {}
    preferences.shortcut = ShortcutDefinition(keyCode: 49, modifiers: 0, displayName: "Space")
    preferences.setOfflineMode(true)
    let ready = OnboardingReadiness.selectedProviders(
      preferences: preferences,
      hasCredential: { _ in
        XCTFail("Offline readiness must not query cloud keys")
        return false
      },
      hasPermissions: true, localModelReady: true)
    XCTAssertTrue(ready.isComplete)
    let missing = OnboardingReadiness.selectedProviders(
      preferences: preferences,
      hasCredential: { _ in false }, hasPermissions: true, localModelReady: false)
    XCTAssertFalse(missing.isComplete)
  }
}

extension DictationCoordinatorTests {
  func testOfflineRoutesLocalAndInsertsRawWithoutReadingCloudKeys() async throws {
    let fixture = makeFixture(
      transcriptionProvider: .meta, hasSonioxKey: false,
      hasMetaKey: false, hasGroqKey: false, cleanupProvider: .groq)
    fixture.preferences.onTranscriptionProviderChange = {}
    fixture.preferences.localTranscriptionModel = .apple
    fixture.preferences.appleSpeechLocale = "en-US"
    fixture.preferences.setOfflineMode(true)
    fixture.coordinator.toggle()
    try await waitUntil { fixture.coordinator.phase == .recording }
    XCTAssertEqual(fixture.transcriber.lastConfiguration?.provider, .local)
    XCTAssertEqual(fixture.transcriber.lastConfiguration?.localModel, .apple)
    XCTAssertEqual(fixture.transcriber.lastConfiguration?.appleLocaleIdentifier, "en-US")
    fixture.coordinator.toggle()
    try await waitUntil { fixture.coordinator.phase == .success }
    XCTAssertEqual(fixture.inserter.insertedText, "Raw transcript")
    XCTAssertTrue(fixture.credentials.readKinds.isEmpty)
    XCTAssertNil(fixture.cleaner.lastConfiguration)
  }

  func testOfflineLocalFailureNeverFallsBackToCloud() async throws {
    let fixture = makeFixture(transcriptionProvider: .soniox, localReady: false)
    fixture.preferences.setOfflineMode(true)
    fixture.coordinator.toggle()
    try await waitUntil {
      if case .error = fixture.coordinator.phase { return true }
      return false
    }
    XCTAssertFalse(fixture.transcriber.didConnect)
    XCTAssertTrue(fixture.credentials.readKinds.isEmpty)
    XCTAssertTrue(fixture.preferences.offlineMode)
  }

  func testHoldPressDuringMenuRecordingWaitsForRelease() async throws {
    let fixture = makeFixture()
    fixture.coordinator.toggle()
    try await waitUntil { fixture.coordinator.phase == .recording }
    let generation = try XCTUnwrap(fixture.coordinator.holdShortcutPressed())
    XCTAssertEqual(fixture.coordinator.phase, .recording)
    fixture.coordinator.finishHeldDictation(lifecycleGeneration: generation)
    try await waitUntil { fixture.coordinator.phase == .success }
  }
}

import Foundation
import XCTest

@testable import AeriVoice

@MainActor
final class CleanupToggleTests: XCTestCase {
  private func withPreferences(_ body: (UserDefaults, AppPreferences) -> Void) {
    let suite = "AeriVoiceTests.CleanupToggle.\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let preferences = AppPreferences(defaults: defaults)
    preferences.onTranscriptionProviderChange = {}
    body(defaults, preferences)
  }

  func testCleanupStaysOnUntilTurnedOffAndTheChoicePersists() {
    withPreferences { defaults, preferences in
      XCTAssertTrue(preferences.cleanupEnabled, "Existing users keep cleanup")
      XCTAssertFalse(preferences.skipsCleanup)

      preferences.cleanupEnabled = false
      XCTAssertTrue(preferences.skipsCleanup)
      XCTAssertFalse(AppPreferences(defaults: defaults).cleanupEnabled)

      preferences.cleanupEnabled = true
      XCTAssertFalse(preferences.skipsCleanup)
      XCTAssertTrue(AppPreferences(defaults: defaults).cleanupEnabled)
    }
  }

  func testOfflineSkipsCleanupAndLeavingItRestoresTheChoice() {
    withPreferences { _, preferences in
      preferences.setOfflineMode(true)
      XCTAssertTrue(preferences.cleanupEnabled, "Offline doesn't change the saved choice")
      XCTAssertTrue(preferences.skipsCleanup)
      preferences.setOfflineMode(false)
      XCTAssertFalse(preferences.skipsCleanup)
    }
  }

  func testSetupNeedsNoCleanupKeyWhileCleanupIsOff() {
    withPreferences { _, preferences in
      preferences.shortcut = ShortcutDefinition(keyCode: 49, modifiers: 0, displayName: "Space")
      let readiness = {
        OnboardingReadiness.selectedProviders(
          preferences: preferences,
          hasCredential: { $0 == preferences.transcriptionProvider.credentialKind },
          hasPermissions: true)
      }
      XCTAssertFalse(readiness().isComplete)
      preferences.cleanupEnabled = false
      XCTAssertTrue(readiness().isComplete)
    }
  }
}

extension DictationCoordinatorTests {
  func testCleanupOffPastesTheTranscriptWithoutACleanupKeyOrRequest() async throws {
    let fixture = makeFixture(hasGroqKey: false, cleanupProvider: .groq)
    fixture.preferences.cleanupEnabled = false
    fixture.coordinator.toggle()
    try await waitUntil { fixture.coordinator.phase == .recording }
    XCTAssertEqual(fixture.transcriber.lastConfiguration?.provider, .soniox)
    fixture.coordinator.toggle()
    try await waitUntil { fixture.coordinator.phase == .success }
    XCTAssertEqual(fixture.inserter.insertedText, "Raw transcript")
    XCTAssertEqual(fixture.credentials.readKinds, [.soniox])
    XCTAssertNil(fixture.cleaner.lastConfiguration)
    XCTAssertFalse(fixture.notch.presentedStates.contains { $0.phase == .cleaning })
    let working = fixture.notch.presentedStates.filter {
      $0.phase == .processing || $0.phase == .inserting
    }
    XCTAssertFalse(working.isEmpty)
    XCTAssertTrue(working.allSatisfy(\.skipsCleanup), "Nothing is refined, so the notch doesn't say so")
    XCTAssertNil(fixture.notch.presentedStates.last?.warning)
    XCTAssertFalse(fixture.cleaner.didRequestWarmUp, "No connection is warmed for cleanup")
  }

  func testChangingCleanupDuringADictationAppliesToTheNextOne() async throws {
    let fixture = makeFixture()
    fixture.coordinator.toggle()
    try await waitUntil { fixture.coordinator.phase == .recording }
    fixture.preferences.cleanupEnabled = false
    fixture.coordinator.toggle()
    try await waitUntil { fixture.coordinator.phase == .success }
    XCTAssertNotNil(fixture.cleaner.lastConfiguration, "The dictation under way keeps cleanup")
    XCTAssertEqual(fixture.inserter.insertedText, "Cleaned text.")
    XCTAssertFalse(fixture.notch.presentedStates.contains(where: \.skipsCleanup))
  }
}

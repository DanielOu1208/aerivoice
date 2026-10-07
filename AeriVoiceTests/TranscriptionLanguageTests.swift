import Foundation
import XCTest

@testable import AeriVoice

final class TranscriptionLanguageTests: XCTestCase {
  func testProviderTablesMatchTheirDocumentation() {
    XCTAssertEqual(TranscriptionLanguage.sonioxCodes.count, 60)
    XCTAssertEqual(TranscriptionLanguage.grokCodes.count, 38)
    XCTAssertEqual(TranscriptionLanguage.metaNames.count, 25)
    XCTAssertEqual(
      Set(TranscriptionLanguage.metaNames.values),
      [
        "Arabic", "Bengali", "Dutch", "English", "French", "German", "Hebrew", "Hindi",
        "Indonesian", "Italian", "Japanese", "Kannada", "Korean", "Malay", "Mandarin Chinese",
        "Marathi", "Polish", "Portuguese", "Spanish", "Tagalog", "Tamil", "Telugu", "Thai",
        "Turkish", "Vietnamese",
      ])
    XCTAssertEqual(TranscriptionLanguage.metaNames["zh"], "Mandarin Chinese")
    XCTAssertTrue(TranscriptionLanguage.grokCodes.isSuperset(of: ["yue", "fil", "nb"]))
    XCTAssertEqual(TranscriptionLanguage.codes(for: .meta), Set(TranscriptionLanguage.metaNames.keys))
    XCTAssertTrue(TranscriptionLanguage.codes(for: .cartesia).isEmpty)
    XCTAssertTrue(TranscriptionLanguage.codes(for: .local).isEmpty)
    // Every code has a name, so the menu never shows a bare code.
    let english = Locale(identifier: "en_US")
    for provider in TranscriptionProvider.allCases {
      for code in TranscriptionLanguage.codes(for: provider) {
        XCTAssertNotEqual(TranscriptionLanguage.displayName(for: code, locale: english), code)
      }
    }
  }

  func testEquivalentCodesCarryALanguageAcrossProviders() {
    XCTAssertEqual(TranscriptionLanguage.resolve("no", for: .grok), "nb")
    XCTAssertEqual(TranscriptionLanguage.resolve("nb", for: .soniox), "no")
    XCTAssertNil(TranscriptionLanguage.resolve("nb", for: .meta))
    XCTAssertEqual(TranscriptionLanguage.resolve("tl", for: .grok), "fil")
    XCTAssertEqual(TranscriptionLanguage.resolve("fil", for: .soniox), "tl")
    XCTAssertEqual(TranscriptionLanguage.resolve("fil", for: .meta), "tl")
    XCTAssertEqual(TranscriptionLanguage.resolve("en", for: .grok), "en")
    XCTAssertNil(TranscriptionLanguage.resolve("cy", for: .grok))
    for (code, equivalent) in TranscriptionLanguage.equivalents {
      XCTAssertEqual(TranscriptionLanguage.equivalents[equivalent], code)
    }
  }

  func testChoicesAreSortedByLanguageName() {
    let english = Locale(identifier: "en_US")
    let names = TranscriptionLanguage.choices(for: .grok, locale: english).map {
      TranscriptionLanguage.displayName(for: $0, locale: english)
    }
    XCTAssertEqual(names.count, 38)
    XCTAssertEqual(names.first, "Arabic")
    XCTAssertEqual(names, names.sorted { $0.localizedStandardCompare($1) == .orderedAscending })
    XCTAssertEqual(TranscriptionLanguage.choices(for: .cartesia), [])
    XCTAssertEqual(TranscriptionLanguage.choices(for: .local), [])
  }

  @MainActor
  func testSpokenLanguageDefaultsToAutoDetectPersistsAndResolvesForEachProvider() {
    let suite = "AeriVoiceTests.TranscriptionLanguage.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let preferences = AppPreferences(defaults: defaults)
    preferences.onTranscriptionProviderChange = {}
    XCTAssertEqual(preferences.transcriptionLanguage, "")
    for provider in TranscriptionProvider.allCases {
      preferences.transcriptionProvider = provider
      XCTAssertNil(preferences.transcriptionConfiguration.language, "\(provider)")
    }

    preferences.transcriptionProvider = .soniox
    preferences.transcriptionLanguage = "en"
    XCTAssertEqual(defaults.string(forKey: "transcriptionLanguage"), "en")
    let english: [(TranscriptionProvider, String?)] = [
      (.soniox, "en"), (.grok, "en"), (.meta, "en"), (.cartesia, nil), (.local, nil),
    ]
    for (provider, language) in english {
      preferences.transcriptionProvider = provider
      XCTAssertEqual(preferences.transcriptionConfiguration.language, language, "\(provider)")
    }

    // Welsh is Soniox's alone: the others detect the language, and the choice is kept.
    preferences.transcriptionProvider = .soniox
    preferences.transcriptionLanguage = "cy"
    XCTAssertEqual(preferences.transcriptionConfiguration.language, "cy")
    preferences.transcriptionProvider = .grok
    XCTAssertNil(preferences.transcriptionConfiguration.language)
    preferences.transcriptionProvider = .meta
    XCTAssertNil(preferences.transcriptionConfiguration.language)
    XCTAssertEqual(preferences.transcriptionLanguage, "cy")
    preferences.transcriptionProvider = .soniox
    XCTAssertEqual(preferences.transcriptionConfiguration.language, "cy")

    // Offline mode transcribes locally, which takes no language.
    preferences.setOfflineMode(true)
    XCTAssertNil(preferences.transcriptionConfiguration.language)
    preferences.setOfflineMode(false)

    let restored = AppPreferences(defaults: defaults)
    XCTAssertEqual(restored.transcriptionLanguage, "cy")
    XCTAssertEqual(restored.transcriptionConfiguration.language, "cy")
    defaults.set("removed-language", forKey: "transcriptionLanguage")
    XCTAssertNil(AppPreferences(defaults: defaults).transcriptionConfiguration.language)
  }

  @MainActor
  func testOnlyALanguageChangeTheProviderIsGivenRefreshesItsConnection() {
    let suite = "AeriVoiceTests.TranscriptionLanguageChange.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let preferences = AppPreferences(defaults: defaults)
    var changes = 0
    preferences.onTranscriptionProviderChange = { changes += 1 }
    preferences.transcriptionProvider = .grok
    changes = 0
    preferences.transcriptionLanguage = "en"
    XCTAssertEqual(changes, 1)
    // Grok doesn't take Welsh, so this is a change from English to detection.
    preferences.transcriptionLanguage = "cy"
    XCTAssertEqual(changes, 2)
    // Still detection for Grok: its prepared connection stays.
    preferences.transcriptionLanguage = ""
    XCTAssertEqual(changes, 2)
    preferences.transcriptionLanguage = "fr"
    XCTAssertEqual(changes, 3)
  }

  func testSettingsExplainWhenNoLanguageIsSent() {
    func note(_ configuration: TranscriptionConfiguration, saved: String) -> String? {
      TranscriptionLanguage.note(for: configuration, saved: saved)
    }
    XCTAssertEqual(
      note(TranscriptionConfiguration(provider: .cartesia), saved: ""),
      "Cartesia detects English, French, Hindi, Japanese and Spanish itself.")
    XCTAssertEqual(
      note(TranscriptionConfiguration(provider: .cartesia, cartesiaModel: .inkPreview), saved: "en"),
      "Cartesia detects English, French, Hindi, Japanese and Spanish itself.")
    XCTAssertEqual(
      note(TranscriptionConfiguration(provider: .local), saved: "en"),
      "Nemotron transcribes English only.")
    XCTAssertEqual(
      note(TranscriptionConfiguration(provider: .local, localModel: .apple), saved: ""),
      "Apple Speech uses its own language, chosen under Manage…")
    XCTAssertNil(note(TranscriptionConfiguration(provider: .grok), saved: ""))
    XCTAssertNil(note(TranscriptionConfiguration(provider: .grok, language: "en"), saved: "en"))
    XCTAssertEqual(
      note(TranscriptionConfiguration(provider: .meta), saved: "cy"),
      "Meta doesn't support \(TranscriptionLanguage.displayName(for: "cy")), so it detects the language.")
  }

  @MainActor
  func testDiagnosticsRecordOnlyTheCodeTheProviderIsGiven() throws {
    let suite = "AeriVoiceTests.TranscriptionLanguageDiagnostics.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let preferences = AppPreferences(defaults: defaults)
    preferences.onTranscriptionProviderChange = {}
    let automatic = try JSONEncoder().encode(DiagnosticSettings(preferences))
    XCTAssertFalse(String(decoding: automatic, as: UTF8.self).contains("transcriptionLanguage"))
    preferences.transcriptionLanguage = "en"
    XCTAssertEqual(DiagnosticSettings(preferences).transcriptionLanguage, "en")
    preferences.transcriptionProvider = .cartesia
    XCTAssertNil(DiagnosticSettings(preferences).transcriptionLanguage)
  }
}

import Foundation

/// The spoken language cloud transcription expects. One code is saved for every provider, and
/// empty means each detects the language; a provider is given the code only if it accepts it.
enum TranscriptionLanguage {
  /// Soniox restricts recognition to the hinted language. From
  /// soniox.com/docs/stt/concepts/supported-languages, fetched 2026-10-06.
  static let sonioxCodes: Set<String> = [
    "af", "ar", "az", "be", "bg", "bn", "bs", "ca", "cs", "cy", "da", "de", "el", "en", "es",
    "et", "eu", "fa", "fi", "fr", "gl", "gu", "he", "hi", "hr", "hu", "id", "it", "ja", "kk",
    "kn", "ko", "lt", "lv", "mk", "ml", "mr", "ms", "nl", "no", "pa", "pl", "pt", "ro", "ru",
    "sk", "sl", "sq", "sr", "sv", "sw", "ta", "te", "th", "tl", "tr", "uk", "ur", "vi", "zh",
  ]

  /// Grok biases recognition toward the language. Regional forms such as pt-BR also exist;
  /// the plain codes are used. From docs.x.ai/developers/model-capabilities/audio/speech-to-text,
  /// fetched 2026-10-06.
  static let grokCodes: Set<String> = [
    "ar", "bg", "bs", "ca", "cs", "da", "de", "el", "en", "es", "fa", "fi", "fil", "fr", "hi",
    "hr", "hu", "id", "it", "ja", "ko", "mk", "ms", "nb", "nl", "pl", "pt", "ro", "ru", "sk",
    "sv", "th", "tr", "uk", "ur", "vi", "yue", "zh",
  ]

  /// Meta biases recognition toward languages given by name, spelled as its documentation lists
  /// them. From dev.meta.ai/docs/speech-to-text, 2026-10-06.
  static let metaNames: [String: String] = [
    "ar": "Arabic", "bn": "Bengali", "de": "German", "en": "English", "es": "Spanish",
    "fr": "French", "he": "Hebrew", "hi": "Hindi", "id": "Indonesian", "it": "Italian",
    "ja": "Japanese", "kn": "Kannada", "ko": "Korean", "mr": "Marathi", "ms": "Malay",
    "nl": "Dutch", "pl": "Polish", "pt": "Portuguese", "ta": "Tamil", "te": "Telugu",
    "th": "Thai", "tl": "Tagalog", "tr": "Turkish", "vi": "Vietnamese", "zh": "Mandarin Chinese",
  ]

  /// The codes a provider accepts; empty when it takes no language.
  static func codes(for provider: TranscriptionProvider) -> Set<String> {
    switch provider {
    case .soniox: sonioxCodes
    case .grok: grokCodes
    case .meta: Set(metaNames.keys)
    // Cartesia's Ink models have no language parameter; Local's models set their own.
    case .cartesia, .local: []
    }
  }

  /// Providers name a few languages with different codes: Soniox and Meta use `no` and `tl`
  /// where Grok uses `nb` (Bokmål, the written Norwegian) and `fil` (Filipino, based on Tagalog).
  static let equivalents: [String: String] = ["no": "nb", "nb": "no", "tl": "fil", "fil": "tl"]

  /// The saved code, or its equivalent, if the provider accepts it; nil lets the provider
  /// detect the language.
  static func resolve(_ code: String, for provider: TranscriptionProvider) -> String? {
    let accepted = codes(for: provider)
    if accepted.contains(code) { return code }
    return equivalents[code].flatMap { accepted.contains($0) ? $0 : nil }
  }

  static func displayName(for code: String, locale: Locale = .current) -> String {
    locale.localizedString(forLanguageCode: code) ?? code
  }

  /// A provider's languages, sorted by name.
  /// Settings asks on every redraw, so each name is looked up once rather than per comparison.
  static func choices(for provider: TranscriptionProvider, locale: Locale = .current) -> [String] {
    codes(for: provider).map { (code: $0, name: displayName(for: $0, locale: locale)) }
      .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
      .map(\.code)
  }

  /// One line for Settings: why no language can be chosen, or why the saved one isn't used.
  static func note(for configuration: TranscriptionConfiguration, saved: String) -> String? {
    switch configuration.provider {
    case .cartesia:
      "Cartesia detects English, French, Hindi, Japanese and Spanish itself."
    case .local:
      configuration.localModel == .apple
        ? "Apple Speech uses its own language, chosen under Manage…"
        : "Nemotron transcribes English only."
    case .soniox, .grok, .meta:
      saved.isEmpty || configuration.language != nil
        ? nil
        : "\(configuration.provider.displayName) doesn't support \(displayName(for: saved)), so it detects the language."
    }
  }
}

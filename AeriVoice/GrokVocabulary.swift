import Foundation

/// Provider limits do not change the user's shared dictionary.
struct GrokVocabulary: Equatable {
  let terms: [String]
  let excluded: [String]

  init(_ vocabulary: [String]) {
    var accepted: [String] = []
    var excluded: [String] = []
    let normalized = VocabularyNormalizer.parse(vocabulary.joined(separator: "\n"))
    for term in normalized {
      if term.unicodeScalars.count <= 50 && accepted.count < 100 {
        accepted.append(term)
      } else {
        excluded.append(term)
      }
    }
    terms = accepted
    self.excluded = excluded
  }
}

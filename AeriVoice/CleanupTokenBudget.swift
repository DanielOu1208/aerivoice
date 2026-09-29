import Foundation

/// Shared arithmetic only; providers retain their own limits and user-facing errors.
enum CleanupTokenBudget {
  static func completionTokens(
    for text: String, systemPrompt: String, allowsExpansion: Bool,
    minimum: Int, maximum: Int, totalLimit: Int, overhead: Int
  ) -> Int? {
    let inputTokens = estimatedTokens(for: text)
    let safetyMargin = max(128, (inputTokens + 3) / 4)
    let completionTokens = min(
      maximum,
      max(minimum, allowsExpansion ? inputTokens * 3 + safetyMargin : inputTokens + safetyMargin))
    let promptTokens = systemPrompt.isEmpty ? 0 : estimatedTokens(for: systemPrompt)
    guard inputTokens + promptTokens + overhead + completionTokens <= totalLimit else {
      return nil
    }
    return completionTokens
  }

  static func estimatedTokens(for text: String) -> Int {
    var asciiBytes = 0
    var nonASCIIBytes = 0
    for byte in text.utf8 {
      if byte < 0x80 {
        asciiBytes += 1
      } else {
        nonASCIIBytes += 1
      }
    }
    return max(1, (asciiBytes + 3) / 4 + (nonASCIIBytes + 1) / 2)
  }
}

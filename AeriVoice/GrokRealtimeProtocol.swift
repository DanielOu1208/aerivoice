import Foundation

struct GrokRealtimeRequest {
  static func make(apiKey: String, vocabulary: [String]) -> URLRequest {
    var components = URLComponents(string: "wss://api.x.ai/v1/stt")!
    components.queryItems = [
      URLQueryItem(name: "model", value: "grok-voice-transcribe-2.0"),
      URLQueryItem(name: "sample_rate", value: "16000"),
      URLQueryItem(name: "encoding", value: "pcm"),
      URLQueryItem(name: "interim_results", value: "true"),
      URLQueryItem(name: "filler_words", value: "true"),
    ] + GrokVocabulary(vocabulary).terms.map { URLQueryItem(name: "keyterm", value: $0) }
    // The endpoint uses form-style query decoding, where a literal + means a space.
    components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
    var request = URLRequest(url: components.url!)
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    return request
  }
}

struct GrokRealtimeResponse: Decodable {
  let type: String
  let text: String?
  let start: Double?
  let duration: Double?
  let isFinal: Bool?
  let speechFinal: Bool?

  enum CodingKeys: String, CodingKey {
    case type, text, start, duration
    case isFinal = "is_final"
    case speechFinal = "speech_final"
  }
}

/// Timestamp ranges distinguish genuine repeated speech from a stitched utterance
/// that replaces already-finalized chunks. Text matching would lose repetitions.
struct GrokTranscriptAssembler {
  private struct Segment {
    let start: Double
    let end: Double
    let text: String
    let final: Bool
  }
  private var segments: [Segment] = []

  var confirmedText: String { Self.join(segments.filter(\.final).map(\.text)) }

  mutating func consume(_ response: GrokRealtimeResponse) throws -> RealtimeTranscriptUpdate {
    guard let text = response.text, let start = response.start, let duration = response.duration,
      start.isFinite, duration.isFinite, start >= 0, duration >= 0,
      let final = response.isFinal, let speechFinal = response.speechFinal
    else { throw AppError.provider("Grok returned an invalid transcript event.") }
    let end = start + duration
    guard end.isFinite else { throw AppError.provider("Grok returned an invalid transcript event.") }
    // Chunk finals are deltas even when their timestamps span the utterance.
    // Only speech_final carries a stitched replacement for that interval.
    segments.removeAll {
      !$0.final || (final && speechFinal && (
        abs($0.start - start) < 0.0001 || ($0.start < end - 0.0001 && $0.end > start + 0.0001)))
    }
    let duplicate = final && segments.contains {
      $0.final && $0.start == start && $0.end == end && $0.text == text
    }
    if !duplicate { segments.append(Segment(start: start, end: end, text: text, final: final)) }
    let confirmed = confirmedText
    let provisional = Self.join(segments.filter { !$0.final }.map(\.text))
    let combined = Self.join([confirmed, provisional])
    return RealtimeTranscriptUpdate(
      snapshot: TranscriptSnapshot(confirmed: confirmed, provisional: String(combined.dropFirst(confirmed.count))),
      hasFinalText: final && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      finalAudioProcessedMS: nil, totalAudioProcessedMS: nil)
  }

  private static func usesUnspacedScript(_ character: Character) -> Bool {
    character.unicodeScalars.contains { scalar in
      switch scalar.value {
      case 0x3400...0x9FFF, 0xF900...0xFAFF, 0x20000...0x323AF, // Han
           0x3040...0x30FF, 0xFF66...0xFF9D, // Japanese kana
           0x0E00...0x0EFF, 0x1780...0x17FF, 0x1000...0x109F: // Thai, Lao, Khmer, Burmese
        true
      default: false
      }
    }
  }

  private static func join(_ parts: [String]) -> String {
    parts.reduce("") { result, part in
      guard let last = result.last, let first = part.first else { return result + part }
      let needsSpace = !last.isWhitespace && !first.isWhitespace
        && !",.!?;:)]}，。！？；：、）】》」』".contains(first)
        && !"([{（【《「『".contains(last)
        && !usesUnspacedScript(last) && !usesUnspacedScript(first)
      return result + (needsSpace ? " " : "") + part
    }
  }
}

/// Never retain a URL, response body, or underlying error: these can contain
/// dictionary terms or credentials in Foundation error userInfo.
struct GrokTransportError: LocalizedError {
  let status: Int?

  var httpStatus: Int? {
    guard let status, (400...599).contains(status) else { return nil }
    return status
  }

  var isProviderRejection: Bool {
    httpStatus != nil || [1008, 1009, 1011, 1013].contains(status ?? 0)
  }

  var errorDescription: String? {
    switch status {
    case 401, 403: "xAI rejected this API key. Check its permissions and API credits."
    case 429, 1013: "xAI is rate limited. Wait a moment and try again."
    default: "The Grok transcription connection failed. Try again."
    }
  }
}

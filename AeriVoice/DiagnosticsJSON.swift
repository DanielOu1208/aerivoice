import Foundation

enum DiagnosticsJSON {
  static func encoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .custom { date, encoder in
      var container = encoder.singleValueContainer()
      try container.encode(date.ISO8601Format(.init(includingFractionalSeconds: true)))
    }
    return encoder
  }

  static func date(_ text: String) -> Date? {
    (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text))
      ?? (try? Date.ISO8601FormatStyle().parse(text))
  }

  static func decoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .custom { decoder in
      let container = try decoder.singleValueContainer()
      let text = try container.decode(String.self)
      guard let date = date(text) else {
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid diagnostic timestamp")
      }
      return date
    }
    return decoder
  }
}

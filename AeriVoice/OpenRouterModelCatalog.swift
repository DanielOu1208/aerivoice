import Foundation

struct OpenRouterCatalogEntry: Codable, Identifiable, Equatable, Sendable {
  let id: String
  let name: String
  let architecture: Architecture
  var reasoning: OpenRouterReasoning? = nil

  struct Architecture: Codable, Equatable, Sendable {
    let inputModalities: [String]
    let outputModalities: [String]

    enum CodingKeys: String, CodingKey {
      case inputModalities = "input_modalities"
      case outputModalities = "output_modalities"
    }
  }

  var cleanupModel: CleanupModel? { CleanupModel(openRouterID: id) }

  var isCleanupCompatible: Bool {
    architecture.inputModalities.contains("text")
      && architecture.outputModalities == ["text"]
      && !id.hasPrefix("openrouter/")
      && cleanupModel != nil
  }

  func matches(_ query: String) -> Bool {
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    return query.isEmpty || name.localizedCaseInsensitiveContains(query)
      || id.localizedCaseInsensitiveContains(query)
  }
}

struct OpenRouterModelCatalog {
  let session: URLSession

  init(session: URLSession = .shared) { self.session = session }

  func fetch() async throws -> [OpenRouterCatalogEntry] {
    var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/models")!)
    request.timeoutInterval = 15
    request.cachePolicy = .reloadIgnoringLocalCacheData
    // The public catalog needs no credential or transcript data.
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
      throw AppError.provider("OpenRouter’s model list is unavailable.")
    }
    return try Self.decode(data)
  }

  static func decode(_ data: Data) throws -> [OpenRouterCatalogEntry] {
    let envelope = try JSONDecoder().decode(Envelope.self, from: data)
    var seen = Set<String>()
    return envelope.data.filter { $0.isCleanupCompatible && seen.insert($0.id).inserted }
      .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }

  private struct Envelope: Decodable { let data: [OpenRouterCatalogEntry] }
}

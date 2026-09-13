import Foundation

struct OpenRouterReasoning: Codable, Equatable, Sendable {
  enum EffortOptions: Equatable, Sendable {
    case unavailable
    case all
    case specific([CleanupReasoningEffort])
  }

  let efforts: EffortOptions
  let defaultEffort: CleanupReasoningEffort?
  let defaultEnabled: Bool?
  let mandatory: Bool
  let supportsMaxTokens: Bool

  var selectableEfforts: [CleanupReasoningEffort] {
    let levels: [CleanupReasoningEffort]
    switch efforts {
    case .unavailable: levels = []
    case .all: levels = CleanupReasoningEffort.gatewayLevels
    case .specific(let advertised): levels = advertised.reversed()
    }
    var seen = Set<CleanupReasoningEffort>()
    return levels.filter {
      $0 != .automatic && !(mandatory && $0 == .none) && seen.insert($0).inserted
    }
  }

  private enum CodingKeys: String, CodingKey {
    case efforts = "supported_efforts"
    case defaultEffort = "default_effort"
    case defaultEnabled = "default_enabled"
    case mandatory
    case supportsMaxTokens = "supports_max_tokens"
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    if !container.contains(.efforts) {
      efforts = .unavailable
    } else if try container.decodeNil(forKey: .efforts) {
      efforts = .all
    } else {
      let values = try container.decode([String].self, forKey: .efforts)
      efforts = .specific(values.compactMap(CleanupReasoningEffort.init(rawValue:)))
    }
    defaultEffort = try container.decodeIfPresent(String.self, forKey: .defaultEffort)
      .flatMap(CleanupReasoningEffort.init(rawValue:))
    defaultEnabled = try container.decodeIfPresent(Bool.self, forKey: .defaultEnabled)
    mandatory = try container.decodeIfPresent(Bool.self, forKey: .mandatory) ?? false
    supportsMaxTokens =
      try container.decodeIfPresent(Bool.self, forKey: .supportsMaxTokens) ?? false
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch efforts {
    case .unavailable: break
    case .all: try container.encodeNil(forKey: .efforts)
    case .specific(let values): try container.encode(values, forKey: .efforts)
    }
    try container.encodeIfPresent(defaultEffort, forKey: .defaultEffort)
    try container.encodeIfPresent(defaultEnabled, forKey: .defaultEnabled)
    try container.encode(mandatory, forKey: .mandatory)
    try container.encode(supportsMaxTokens, forKey: .supportsMaxTokens)
  }
}

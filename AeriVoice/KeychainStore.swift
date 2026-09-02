import Foundation
import Security

enum CredentialKind: String, CaseIterable, Sendable {
  case soniox
  case metaModelAPI
  case openRouter
  case groq

  var label: String {
    switch self {
    case .soniox: "Soniox"
    case .metaModelAPI: "Meta Model API"
    case .openRouter: "OpenRouter"
    case .groq: "Groq"
    }
  }

  var apiKeyLabel: String {
    switch self {
    case .metaModelAPI: "Meta Model API key"
    default: "\(label) API key"
    }
  }
}

enum CredentialNamespace: String, Sendable {
  case legacyRelease = "credentials"
  case development = "credentials.development"
  case releaseV2 = "credentials.v2"

  static var current: Self {
    #if AERIVOICE_DISTRIBUTION
      .releaseV2
    #else
      .development
    #endif
  }
}

enum KeychainAuthenticationPolicy: Sendable {
  case skip
  case allow
}

protocol CredentialReading: Sendable {
  func value(for kind: CredentialKind) -> String?
}

protocol CredentialPresenceReading: CredentialReading {
  func containsCredential(_ kind: CredentialKind) -> Bool
}

protocol CredentialStoring: CredentialPresenceReading {
  func addIfMissing(_ value: String, for kind: CredentialKind) throws -> Bool
  func save(_ value: String, for kind: CredentialKind) throws
  func remove(_ kind: CredentialKind) throws
}

final class KeychainStore: CredentialStoring, @unchecked Sendable {
  private let service: String
  private let authenticationPolicy: KeychainAuthenticationPolicy

  init(
    bundleIdentifier: String? = Bundle.main.bundleIdentifier,
    namespace: CredentialNamespace = .current,
    authenticationPolicy: KeychainAuthenticationPolicy = .skip
  ) {
    service = Self.serviceName(bundleIdentifier: bundleIdentifier, namespace: namespace)
    self.authenticationPolicy = authenticationPolicy
  }

  static func serviceName(
    bundleIdentifier: String?, namespace: CredentialNamespace
  ) -> String {
    "\(bundleIdentifier ?? "com.danielou.AeriVoice").\(namespace.rawValue)"
  }

  func value(for kind: CredentialKind) -> String? {
    let query = Self.valueQuery(
      service: service, kind: kind, authenticationPolicy: authenticationPolicy)
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    if status == errSecSuccess, let data = item as? Data {
      return String(data: data, encoding: .utf8)
    }
    return nil
  }

  func containsCredential(_ kind: CredentialKind) -> Bool {
    let query = Self.presenceQuery(service: service, kind: kind)
    var item: CFTypeRef?
    return SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess
  }

  func save(_ value: String, for kind: CredentialKind) throws {
    let data = Data(value.utf8)
    let query = Self.baseQuery(service: service, kind: kind)
    var existingItem: CFTypeRef?
    let status = SecItemCopyMatching(
      Self.valueQuery(service: service, kind: kind) as CFDictionary, &existingItem)
    let result: OSStatus
    switch status {
    case errSecSuccess:
      result = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    case errSecItemNotFound:
      var add = query
      add[kSecValueData as String] = data
      result = SecItemAdd(add as CFDictionary, nil)
    default:
      throw KeychainError.status(status)
    }
    guard result == errSecSuccess else { throw KeychainError.status(result) }
  }

  func addIfMissing(_ value: String, for kind: CredentialKind) throws -> Bool {
    var item = Self.baseQuery(service: service, kind: kind)
    item[kSecValueData as String] = Data(value.utf8)
    switch SecItemAdd(item as CFDictionary, nil) {
    case errSecSuccess:
      return true
    case errSecDuplicateItem:
      return false
    case let status:
      throw KeychainError.status(status)
    }
  }

  func remove(_ kind: CredentialKind) throws {
    var existingItem: CFTypeRef?
    let lookupStatus = SecItemCopyMatching(
      Self.valueQuery(service: service, kind: kind) as CFDictionary, &existingItem)
    guard lookupStatus == errSecSuccess || lookupStatus == errSecItemNotFound else {
      throw KeychainError.status(lookupStatus)
    }
    guard lookupStatus == errSecSuccess else { throw KeychainError.credentialUnavailable }
    let query = Self.baseQuery(service: service, kind: kind)
    let status = SecItemDelete(query as CFDictionary)
    guard status == errSecSuccess else { throw KeychainError.status(status) }
  }

  static func baseQuery(service: String, kind: CredentialKind) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: kind.rawValue,
    ]
  }

  static func presenceQuery(service: String, kind: CredentialKind) -> [String: Any] {
    var query = baseQuery(service: service, kind: kind)
    query[kSecReturnAttributes as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUISkip
    return query
  }

  static func valueQuery(
    service: String, kind: CredentialKind,
    authenticationPolicy: KeychainAuthenticationPolicy = .skip
  ) -> [String: Any] {
    var query = baseQuery(service: service, kind: kind)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    switch authenticationPolicy {
    case .skip:
      query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUISkip
    case .allow:
      break
    }
    return query
  }
}

enum KeychainError: LocalizedError {
  case credentialUnavailable
  case status(OSStatus)
  var errorDescription: String? {
    switch self {
    case .credentialUnavailable:
      "macOS blocked access to this AeriVoice credential. Remove the AeriVoice item in Keychain Access, then reconnect it."
    case .status(errSecDuplicateItem), .status(errSecInteractionNotAllowed),
      .status(errSecAuthFailed):
      "macOS blocked access to this AeriVoice credential. Remove the AeriVoice item in Keychain Access, then reconnect it."
    case .status(let status):
      SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)"
    }
  }
}

import Foundation
import Security

enum CredentialKind: String, CaseIterable, Sendable {
  case soniox
  case openRouter
  case groq

  var label: String {
    switch self {
    case .soniox: "Soniox"
    case .openRouter: "OpenRouter"
    case .groq: "Groq"
    }
  }
}

protocol CredentialReading: Sendable {
  func value(for kind: CredentialKind) -> String?
}

protocol CredentialStoring: CredentialReading {
  func save(_ value: String, for kind: CredentialKind) throws
  func remove(_ kind: CredentialKind) throws
}

final class KeychainStore: CredentialStoring, @unchecked Sendable {
  private let service: String

  init(bundleIdentifier: String? = Bundle.main.bundleIdentifier) {
    service = Self.serviceName(bundleIdentifier: bundleIdentifier)
  }

  static func serviceName(bundleIdentifier: String?) -> String {
    "\(bundleIdentifier ?? "com.danielou.AeriVoice").credentials"
  }

  func value(for kind: CredentialKind) -> String? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: kind.rawValue,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
      let data = item as? Data
    else { return nil }
    return String(data: data, encoding: .utf8)
  }

  func save(_ value: String, for kind: CredentialKind) throws {
    let data = Data(value.utf8)
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: kind.rawValue,
    ]
    let status = SecItemCopyMatching(query as CFDictionary, nil)
    let result: OSStatus
    if status == errSecSuccess {
      result = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    } else {
      var add = query
      add[kSecValueData as String] = data
      add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
      result = SecItemAdd(add as CFDictionary, nil)
    }
    guard result == errSecSuccess else { throw KeychainError.status(result) }
  }

  func remove(_ kind: CredentialKind) throws {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: kind.rawValue,
    ]
    let status = SecItemDelete(query as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw KeychainError.status(status)
    }
  }
}

enum KeychainError: LocalizedError {
  case status(OSStatus)
  var errorDescription: String? {
    switch self {
    case .status(let status):
      SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)"
    }
  }
}

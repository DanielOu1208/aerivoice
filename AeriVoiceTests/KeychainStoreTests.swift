import Security
import XCTest

@testable import AeriVoice

final class KeychainStoreTests: XCTestCase {
  func testCredentialPresenceLookupDoesNotRequestSecretData() {
    let query = KeychainStore.presenceQuery(
      service: "com.danielou.AeriVoiceTests.credentials", kind: .soniox)

    XCTAssertEqual(
      query[kSecAttrService as String] as? String,
      "com.danielou.AeriVoiceTests.credentials")
    XCTAssertEqual(query[kSecAttrAccount as String] as? String, CredentialKind.soniox.rawValue)
    XCTAssertEqual(
      query[kSecUseAuthenticationUI as String] as? String,
      kSecUseAuthenticationUISkip as String)
    XCTAssertEqual(query[kSecReturnAttributes as String] as? Bool, true)
    XCTAssertNil(query[kSecReturnData as String])
    XCTAssertNil(query[kSecUseDataProtectionKeychain as String])
  }

  func testCredentialValueLookupRequestsSecretData() {
    let query = KeychainStore.valueQuery(
      service: "com.danielou.AeriVoiceTests.credentials", kind: .soniox)

    XCTAssertEqual(query[kSecReturnData as String] as? Bool, true)
    XCTAssertNil(query[kSecReturnAttributes as String])
  }

  func testBlockedCredentialErrorProvidesRecovery() {
    let message = KeychainError.credentialUnavailable.errorDescription

    XCTAssertEqual(
      message,
      "macOS blocked access to this AeriVoice credential. Remove the AeriVoice item in Keychain Access, then reconnect it.")
  }
}

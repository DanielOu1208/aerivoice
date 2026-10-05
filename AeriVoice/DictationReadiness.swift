import AVFoundation
import AppKit

@MainActor
protocol DictationReadinessChecking: Sendable {
  /// Microphone access is already granted; asking would show no prompt.
  var microphoneAuthorized: Bool { get }
  func requestMicrophone() async -> Bool
  func accessibilityReady(prompt: Bool) -> Bool
}

struct SystemDictationReadiness: DictationReadinessChecking {
  var microphoneAuthorized: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }

  func requestMicrophone() async -> Bool {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized: true
    case .notDetermined: await AVCaptureDevice.requestAccess(for: .audio)
    default: false
    }
  }

  func accessibilityReady(prompt: Bool) -> Bool {
    guard !AXIsProcessTrusted(), prompt else { return AXIsProcessTrusted() }
    _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    return false
  }
}

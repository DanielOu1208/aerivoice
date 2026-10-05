import Foundation

/// Internal evaluation switch; both modes preserve every captured PCM byte.
enum GrokAudioPacketPolicy: Sendable {
  case captureFrames
  case milliseconds100
}

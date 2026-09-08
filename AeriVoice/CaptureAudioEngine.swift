@preconcurrency import AVFoundation
import CoreAudio
import Foundation

/// All engine operations are confined to AudioCaptureService's serial queue.
protocol CaptureAudioEngine: AnyObject, Sendable {
  var notificationObject: AnyObject { get }
  func prepare() throws
  func start(
    checkCancellation: @Sendable () throws -> Void,
    onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void
  ) throws
  func stop()
}

final class SystemCaptureAudioEngine: CaptureAudioEngine, @unchecked Sendable {
  private let engine = AVAudioEngine()
  private var tapInstalled = false

  var notificationObject: AnyObject { engine }

  func prepare() throws {
    try validateInput()
    // No tap and no engine.start(): preparation must not capture microphone audio.
    engine.prepare()
  }

  func start(
    checkCancellation: @Sendable () throws -> Void,
    onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void
  ) throws {
    try checkCancellation()
    try validateInput()
    try checkCancellation()
    engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, _ in
      onBuffer(buffer)
    }
    tapInstalled = true
    // Installing the tap changes the graph; prepare its capture resources now.
    engine.prepare()
    try checkCancellation()
    try engine.start()
  }

  func stop() {
    if tapInstalled {
      engine.inputNode.removeTap(onBus: 0)
      tapInstalled = false
    }
    if engine.isRunning { engine.stop() }
  }

  private func validateInput() throws {
    let format = engine.inputNode.inputFormat(forBus: 0)
    guard format.sampleRate > 0, format.channelCount > 0 else {
      throw AppError.microphoneUnavailable
    }
  }
}

/// A validation snapshot only; capture always uses the current callback's format.
struct AudioInputRoute: Equatable, Sendable {
  let deviceID: AudioDeviceID
  let sampleRate: Float64
  let channels: UInt32

  static func current() -> Self? {
    var device = AudioDeviceID(0)
    var size = UInt32(MemoryLayout.size(ofValue: device))
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultInputDevice,
      mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    guard
      AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
      device != kAudioObjectUnknown
    else { return nil }

    var rate: Float64 = 0
    size = UInt32(MemoryLayout.size(ofValue: rate))
    address.mSelector = kAudioDevicePropertyNominalSampleRate
    guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &rate) == noErr,
      rate > 0
    else { return nil }

    address.mSelector = kAudioDevicePropertyStreamConfiguration
    address.mScope = kAudioDevicePropertyScopeInput
    guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr,
      size >= MemoryLayout<AudioBufferList>.size
    else { return nil }
    let storage = UnsafeMutableRawPointer.allocate(
      byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { storage.deallocate() }
    guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, storage) == noErr else {
      return nil
    }
    let buffers = UnsafeMutableAudioBufferListPointer(
      storage.bindMemory(to: AudioBufferList.self, capacity: 1))
    let channels = buffers.reduce(UInt32(0)) { $0 + $1.mNumberChannels }
    guard channels > 0 else { return nil }
    return Self(deviceID: device, sampleRate: rate, channels: channels)
  }
}

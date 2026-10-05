@preconcurrency import AVFoundation
import CoreAudio
import Foundation

/// All engine operations are confined to AudioCaptureService's serial queue.
protocol CaptureAudioEngine: AnyObject, Sendable {
  var notificationObject: AnyObject { get }
  var isRunning: Bool { get }
  func prepare() throws
  /// `onBuffer` also receives the host time of the block's first frame, or nil when the
  /// engine doesn't know it.
  func start(
    checkCancellation: @Sendable () throws -> Void,
    onBuffer: @escaping @Sendable (AVAudioPCMBuffer, UInt64?) -> Void
  ) throws -> CaptureEngineStartSteps
  func stop()
}

/// How long each step of an engine start took. Content-free.
struct CaptureEngineStartSteps: Equatable, Sendable {
  /// Checking the input format and installing the capture tap.
  var tapInstall: Duration = .zero
  /// Preparing the graph again now that it has a tap.
  var prepare: Duration = .zero
  /// Starting the hardware.
  var start: Duration = .zero
}

final class SystemCaptureAudioEngine: CaptureAudioEngine, @unchecked Sendable {
  private let engine = AVAudioEngine()
  private var tapInstalled = false
  private var deviceSelectionFailed = false

  /// A nil device follows the system default input.
  init(deviceID: AudioDeviceID? = nil) {
    guard var deviceID, let unit = engine.inputNode.audioUnit else { return }
    // The device must be selected before the input format is read or the engine is prepared.
    deviceSelectionFailed =
      AudioUnitSetProperty(
        unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &deviceID,
        UInt32(MemoryLayout<AudioDeviceID>.size)) != noErr
  }

  var notificationObject: AnyObject { engine }
  var isRunning: Bool { engine.isRunning }

  func prepare() throws {
    try validateInput()
    // No tap and no engine.start(): preparation must not capture microphone audio.
    engine.prepare()
  }

  func start(
    checkCancellation: @Sendable () throws -> Void,
    onBuffer: @escaping @Sendable (AVAudioPCMBuffer, UInt64?) -> Void
  ) throws -> CaptureEngineStartSteps {
    let clock = ContinuousClock()
    var steps = CaptureEngineStartSteps()
    try checkCancellation()
    var started = clock.now
    try validateInput()
    try checkCancellation()
    engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, when in
      onBuffer(buffer, when.isHostTimeValid ? when.hostTime : nil)
    }
    tapInstalled = true
    steps.tapInstall = started.duration(to: clock.now)
    // Installing the tap changes the graph; prepare its capture resources now.
    started = clock.now
    engine.prepare()
    steps.prepare = started.duration(to: clock.now)
    try checkCancellation()
    started = clock.now
    try engine.start()
    steps.start = started.duration(to: clock.now)
    return steps
  }

  func stop() {
    if tapInstalled {
      engine.inputNode.removeTap(onBus: 0)
      tapInstalled = false
    }
    if engine.isRunning { engine.stop() }
  }

  private func validateInput() throws {
    guard !deviceSelectionFailed else { throw AppError.microphoneUnavailable }
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
  /// True when the user's chosen device is used instead of following the system default.
  var pinned = false
  var isBluetooth = false

  /// Uses the preferred device when it is connected; otherwise the system default input.
  static func current(preferredDeviceUID: String? = nil) -> Self? {
    if let preferredDeviceUID, let device = AudioInputDevice.deviceID(forUID: preferredDeviceUID),
      var route = route(for: device)
    {
      route.pinned = true
      return route
    }
    guard let device = AudioInputDevice.defaultInputDeviceID() else { return nil }
    return route(for: device)
  }

  private static func route(for device: AudioDeviceID) -> Self? {
    var rate: Float64 = 0
    var size = UInt32(MemoryLayout.size(ofValue: rate))
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyNominalSampleRate,
      mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &rate) == noErr,
      rate > 0
    else { return nil }

    let channels = AudioInputDevice.inputChannelCount(device)
    guard channels > 0 else { return nil }
    let transport = AudioInputDevice.transportType(device)
    return Self(
      deviceID: device, sampleRate: rate, channels: channels,
      isBluetooth: transport == kAudioDeviceTransportTypeBluetooth
        || transport == kAudioDeviceTransportTypeBluetoothLE)
  }
}

/// A connected device that can supply microphone input.
struct AudioInputDevice: Identifiable, Equatable, Sendable {
  let uid: String
  let name: String

  var id: String { uid }

  static func all() -> [Self] {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    let system = AudioObjectID(kAudioObjectSystemObject)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else {
      return []
    }
    var devices = [AudioDeviceID](
      repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &devices) == noErr else {
      return []
    }
    return devices.compactMap { device in
      guard inputChannelCount(device) > 0,
        let uid = stringProperty(kAudioDevicePropertyDeviceUID, of: device),
        let name = stringProperty(kAudioObjectPropertyName, of: device)
      else { return nil }
      return Self(uid: uid, name: name)
    }
  }

  static func defaultInputDeviceID() -> AudioDeviceID? {
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
    return device
  }

  static func deviceID(forUID uid: String) -> AudioDeviceID? {
    var device = AudioDeviceID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout.size(ofValue: device))
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
      mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var cfUID = uid as CFString
    let status = withUnsafeMutablePointer(to: &cfUID) { pointer in
      AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &address,
        UInt32(MemoryLayout<CFString>.size), pointer, &size, &device)
    }
    guard status == noErr, device != kAudioObjectUnknown, inputChannelCount(device) > 0 else {
      return nil
    }
    return device
  }

  static func inputChannelCount(_ device: AudioDeviceID) -> UInt32 {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyStreamConfiguration,
      mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr,
      size >= MemoryLayout<AudioBufferList>.size
    else { return 0 }
    let storage = UnsafeMutableRawPointer.allocate(
      byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { storage.deallocate() }
    guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, storage) == noErr else {
      return 0
    }
    let buffers = UnsafeMutableAudioBufferListPointer(
      storage.bindMemory(to: AudioBufferList.self, capacity: 1))
    return buffers.reduce(UInt32(0)) { $0 + $1.mNumberChannels }
  }

  static func transportType(_ device: AudioDeviceID) -> UInt32 {
    var type: UInt32 = 0
    var size = UInt32(MemoryLayout.size(ofValue: type))
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyTransportType, mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &type) == noErr ? type : 0
  }

  private static func stringProperty(
    _ selector: AudioObjectPropertySelector, of device: AudioDeviceID
  ) -> String? {
    var address = AudioObjectPropertyAddress(
      mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr,
      let value
    else { return nil }
    return value.takeRetainedValue() as String
  }
}

/// Keeps the Settings input picker current as devices connect and disconnect.
@MainActor
final class AudioInputDeviceList: ObservableObject {
  @Published private(set) var devices: [AudioInputDevice] = []
  // Written once in init and read in deinit only.
  nonisolated(unsafe) private var listener: AudioObjectPropertyListenerBlock?
  nonisolated(unsafe) private var address = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain)

  init() {
    refresh()
    let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
      MainActor.assumeIsolated { self?.refresh() }
    }
    if AudioObjectAddPropertyListenerBlock(
      AudioObjectID(kAudioObjectSystemObject), &address, .main, listener) == noErr
    {
      self.listener = listener
    }
  }

  deinit {
    guard let listener else { return }
    var address = address
    AudioObjectRemovePropertyListenerBlock(
      AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
  }

  func refresh() {
    let current = AudioInputDevice.all()
    if current != devices { devices = current }
  }
}

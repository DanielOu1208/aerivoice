@preconcurrency import CoreAudio
import Foundation

struct OutputRestoreRecord: Codable, Equatable {
  let deviceID: AudioDeviceID
  let deviceUID: String?
  let element: AudioObjectPropertyElement
  let usedMute: Bool
  let originalValue: Float32
  let appliedValue: Float32

  init(
    deviceID: AudioDeviceID, deviceUID: String? = nil, element: AudioObjectPropertyElement,
    usedMute: Bool, originalValue: Float32, appliedValue: Float32
  ) {
    self.deviceID = deviceID
    self.deviceUID = deviceUID
    self.element = element
    self.usedMute = usedMute
    self.originalValue = originalValue
    self.appliedValue = appliedValue
  }

  var key: String { "\(deviceUID ?? "legacy-\(deviceID)"):\(element):\(usedMute)" }
}

final class OutputDeviceObservation: @unchecked Sendable {
  private let lock = NSLock()
  private var cancellation: (() -> Void)?

  init(cancellation: @escaping () -> Void) {
    self.cancellation = cancellation
  }

  func cancel() {
    lock.lock()
    let action = cancellation
    cancellation = nil
    lock.unlock()
    action?()
  }

  deinit { cancel() }
}

protocol OutputAudioBackend: AnyObject, Sendable {
  func defaultOutputDevice() -> AudioDeviceID?
  func deviceUID(_ device: AudioDeviceID) -> String?
  func deviceID(forUID uid: String) -> AudioDeviceID?
  func readVolume(_ device: AudioDeviceID, element: AudioObjectPropertyElement) -> Float32?
  func readMute(_ device: AudioDeviceID, element: AudioObjectPropertyElement) -> UInt32?
  func setVolume(
    _ device: AudioDeviceID, element: AudioObjectPropertyElement, value: Float32
  ) -> Bool
  func setMute(_ device: AudioDeviceID, element: AudioObjectPropertyElement, value: UInt32) -> Bool
  func observeOutputDeviceChanges(
    on queue: DispatchQueue, handler: @escaping @Sendable () -> Void
  ) -> OutputDeviceObservation?
}

final class OutputMuteController: OutputMuting, @unchecked Sendable {
  private let queue = DispatchQueue(label: "com.danielou.AeriVoice.output-mute")
  private let defaults: UserDefaults
  private let backend: OutputAudioBackend
  private var records: [String: OutputRestoreRecord] = [:]
  private var activeObservation: OutputDeviceObservation?
  private var recoveryObservation: OutputDeviceObservation?
  private var activeGeneration: UUID?
  private var restoreGeneration = UUID()
  private var recoveryPollGeneration: UUID?
  private let markerKey = "outputRestoreRecords"
  private let retryDelays: [DispatchTimeInterval] = [
    .milliseconds(50), .milliseconds(250), .seconds(1),
  ]

  init(
    defaults: UserDefaults = .standard,
    backend: OutputAudioBackend = CoreAudioOutputBackend()
  ) {
    self.defaults = defaults
    self.backend = backend
    queue.sync { recoverAfterCrashLocked() }
  }

  func mute() -> Bool {
    queue.sync {
      if activeGeneration != nil { return true }
      recoveryObservation?.cancel()
      recoveryObservation = nil
      recoveryPollGeneration = nil
      restoreGeneration = UUID()
      let generation = UUID()
      activeGeneration = generation
      guard let device = backend.defaultOutputDevice(), muteLocked(device) else {
        activeGeneration = nil
        return false
      }
      beginObservingDefaultDevice(generation: generation)
      persistLocked()
      return true
    }
  }

  func restore() {
    queue.sync {
      activeGeneration = nil
      activeObservation?.cancel()
      activeObservation = nil
      recoveryObservation?.cancel()
      recoveryObservation = nil
      recoveryPollGeneration = nil
      let generation = UUID()
      restoreGeneration = generation
      attemptRestoreLocked(generation: generation, retryIndex: 0)
    }
  }

  private func muteLocked(_ device: AudioDeviceID) -> Bool {
    guard let deviceUID = backend.deviceUID(device) else { return false }
    let main = kAudioObjectPropertyElementMain
    if let existing = records.values.first(where: {
      $0.deviceUID == deviceUID && $0.usedMute
    }),
      backend.readMute(device, element: existing.element) == UInt32(existing.appliedValue)
    {
      return true
    }
    if let original = backend.readMute(device, element: main) {
      let record = OutputRestoreRecord(
        deviceID: device, deviceUID: deviceUID, element: main, usedMute: true,
        originalValue: Float32(original), appliedValue: 1)
      if applyLocked(record) {
        return true
      }
    }
    if let existing = records.values.first(where: {
      $0.deviceUID == deviceUID && $0.element == main && !$0.usedMute
    }),
      backend.readVolume(device, element: existing.element).map({
        OutputRestorePolicy.matches($0, existing.appliedValue)
      }) == true
    {
      return true
    }
    if let original = backend.readVolume(device, element: main) {
      let record = OutputRestoreRecord(
        deviceID: device, deviceUID: deviceUID, element: main, usedMute: false,
        originalValue: original, appliedValue: 0)
      if applyLocked(record) {
        return true
      }
    }
    var foundChannel = false
    var mutedEveryChannel = true
    for element in AudioObjectPropertyElement(1)...AudioObjectPropertyElement(32) {
      if let existing = records.values.first(where: {
        $0.deviceUID == deviceUID && $0.element == element && !$0.usedMute
      }),
        backend.readVolume(device, element: element).map({
          OutputRestorePolicy.matches($0, existing.appliedValue)
        }) == true
      {
        foundChannel = true
        continue
      }
      guard let original = backend.readVolume(device, element: element) else { continue }
      foundChannel = true
      let record = OutputRestoreRecord(
        deviceID: device, deviceUID: deviceUID, element: element, usedMute: false,
        originalValue: original, appliedValue: 0)
      if !applyLocked(record) { mutedEveryChannel = false }
    }
    return foundChannel && mutedEveryChannel
  }

  private func applyLocked(_ record: OutputRestoreRecord) -> Bool {
    records[record.key] = record
    persistLocked()

    if record.usedMute {
      let applied = UInt32(record.appliedValue)
      _ = backend.setMute(record.deviceID, element: record.element, value: applied)
      guard let current = backend.readMute(record.deviceID, element: record.element) else {
        return false
      }
      guard current == applied else {
        discardFailedRecordLocked(record)
        return false
      }
      return true
    }

    _ = backend.setVolume(
      record.deviceID, element: record.element, value: record.appliedValue)
    guard let current = backend.readVolume(record.deviceID, element: record.element) else {
      return false
    }
    guard OutputRestorePolicy.matches(current, record.appliedValue) else {
      discardFailedRecordLocked(record)
      return false
    }
    return true
  }

  private func discardFailedRecordLocked(_ record: OutputRestoreRecord) {
    records.removeValue(forKey: record.key)
    persistLocked()
  }

  private func attemptRestoreLocked(generation: UUID, retryIndex: Int) {
    guard activeGeneration == nil, restoreGeneration == generation else { return }
    let resolvedKeys = records.compactMap { key, record in
      restoreRecordLocked(record) == .resolved ? key : nil
    }
    for key in resolvedKeys { records.removeValue(forKey: key) }
    persistLocked()
    guard !records.isEmpty else {
      recoveryObservation?.cancel()
      recoveryObservation = nil
      recoveryPollGeneration = nil
      return
    }
    beginObservingForRecovery(generation: generation)
    scheduleRecoveryPoll(generation: generation)
    guard retryIndex < retryDelays.count else { return }
    queue.asyncAfter(deadline: .now() + retryDelays[retryIndex]) { [weak self] in
      self?.attemptRestoreLocked(generation: generation, retryIndex: retryIndex + 1)
    }
  }

  private func restoreRecordLocked(_ record: OutputRestoreRecord) -> RestoreDisposition {
    guard let deviceUID = record.deviceUID else { return .resolved }
    guard let device = backend.deviceID(forUID: deviceUID) else { return .retry }
    if record.usedMute {
      guard let current = backend.readMute(device, element: record.element) else {
        return .retry
      }
      let original = UInt32(record.originalValue)
      let applied = UInt32(record.appliedValue)
      if current == original { return .resolved }
      guard current == applied else { return .resolved }
      guard backend.setMute(device, element: record.element, value: original),
        backend.readMute(device, element: record.element) == original
      else { return .retry }
      return .resolved
    }

    guard let current = backend.readVolume(device, element: record.element) else {
      return .retry
    }
    if OutputRestorePolicy.matches(current, record.originalValue) { return .resolved }
    guard OutputRestorePolicy.shouldRestore(current: current, applied: record.appliedValue) else {
      return .resolved
    }
    guard
      backend.setVolume(
        device, element: record.element, value: record.originalValue),
      backend.readVolume(device, element: record.element).map({
        OutputRestorePolicy.matches($0, record.originalValue)
      }) == true
    else { return .retry }
    return .resolved
  }

  private func recoverAfterCrashLocked() {
    guard let data = defaults.data(forKey: markerKey),
      let saved = try? JSONDecoder().decode([OutputRestoreRecord].self, from: data)
    else { return }
    records = Dictionary(uniqueKeysWithValues: saved.map { ($0.key, $0) })
    let generation = UUID()
    restoreGeneration = generation
    attemptRestoreLocked(generation: generation, retryIndex: 0)
  }

  private func persistLocked() {
    guard !records.isEmpty else {
      defaults.removeObject(forKey: markerKey)
      return
    }
    if let data = try? JSONEncoder().encode(Array(records.values)) {
      defaults.set(data, forKey: markerKey)
    }
  }

  private func beginObservingDefaultDevice(generation: UUID) {
    activeObservation?.cancel()
    activeObservation = backend.observeOutputDeviceChanges(on: queue) { [weak self] in
      guard let self, self.activeGeneration == generation,
        let device = self.backend.defaultOutputDevice(), self.muteLocked(device)
      else { return }
      self.persistLocked()
    }
  }

  private func beginObservingForRecovery(generation: UUID) {
    guard recoveryObservation == nil else { return }
    recoveryObservation = backend.observeOutputDeviceChanges(on: queue) { [weak self] in
      guard let self, self.activeGeneration == nil, self.restoreGeneration == generation else {
        return
      }
      self.attemptRestoreLocked(generation: generation, retryIndex: self.retryDelays.count)
    }
  }

  private func scheduleRecoveryPoll(generation: UUID) {
    guard recoveryPollGeneration != generation else { return }
    recoveryPollGeneration = generation
    queue.asyncAfter(deadline: .now() + .seconds(10)) { [weak self] in
      guard let self, self.recoveryPollGeneration == generation else { return }
      self.recoveryPollGeneration = nil
      self.attemptRestoreLocked(generation: generation, retryIndex: self.retryDelays.count)
    }
  }

  private enum RestoreDisposition {
    case resolved
    case retry
  }
}

final class CoreAudioOutputBackend: OutputAudioBackend, @unchecked Sendable {
  func defaultOutputDevice() -> AudioDeviceID? {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultOutputDevice,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var device = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    guard
      AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
      device != kAudioObjectUnknown
    else { return nil }
    return device
  }

  func deviceUID(_ device: AudioDeviceID) -> String? {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyDeviceUID,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    guard AudioObjectHasProperty(device, &address) else { return nil }
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr,
      let value
    else {
      return nil
    }
    return value.takeRetainedValue() as String
  }

  func deviceID(forUID uid: String) -> AudioDeviceID? {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    var qualifier = uid as CFString
    var device = AudioDeviceID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    let status = withUnsafePointer(to: &qualifier) { qualifierPointer in
      AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<CFString>.size),
        qualifierPointer, &size, &device)
    }
    guard status == noErr, device != kAudioObjectUnknown else { return nil }
    return device
  }

  func readVolume(_ device: AudioDeviceID, element: AudioObjectPropertyElement) -> Float32? {
    let selector = kAudioDevicePropertyVolumeScalar
    var address = address(selector, element: element)
    guard AudioObjectHasProperty(device, &address) else { return nil }
    var value: Float32 = 0
    var size = UInt32(MemoryLayout<Float32>.size)
    guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else {
      return nil
    }
    return value
  }

  func readMute(_ device: AudioDeviceID, element: AudioObjectPropertyElement) -> UInt32? {
    let selector = kAudioDevicePropertyMute
    var address = address(selector, element: element)
    guard AudioObjectHasProperty(device, &address) else { return nil }
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else {
      return nil
    }
    return value
  }

  func setVolume(
    _ device: AudioDeviceID, element: AudioObjectPropertyElement, value: Float32
  ) -> Bool {
    let selector = kAudioDevicePropertyVolumeScalar
    guard var address = settableAddress(device, selector: selector, element: element) else {
      return false
    }
    var mutable = value
    return AudioObjectSetPropertyData(
      device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &mutable) == noErr
  }

  func setMute(
    _ device: AudioDeviceID, element: AudioObjectPropertyElement, value: UInt32
  ) -> Bool {
    let selector = kAudioDevicePropertyMute
    guard var address = settableAddress(device, selector: selector, element: element) else {
      return false
    }
    var mutable = value
    return AudioObjectSetPropertyData(
      device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &mutable) == noErr
  }

  func observeOutputDeviceChanges(
    on queue: DispatchQueue, handler: @escaping @Sendable () -> Void
  ) -> OutputDeviceObservation? {
    var addresses = [
      AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain),
      AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain),
    ]
    let listener: AudioObjectPropertyListenerBlock = { _, _ in handler() }
    var installedAddresses: [AudioObjectPropertyAddress] = []
    for index in addresses.indices {
      guard
        AudioObjectAddPropertyListenerBlock(
          AudioObjectID(kAudioObjectSystemObject), &addresses[index], queue, listener) == noErr
      else { continue }
      installedAddresses.append(addresses[index])
    }
    guard !installedAddresses.isEmpty else { return nil }
    return OutputDeviceObservation {
      for index in installedAddresses.indices {
        AudioObjectRemovePropertyListenerBlock(
          AudioObjectID(kAudioObjectSystemObject), &installedAddresses[index], queue, listener)
      }
    }
  }

  private func address(
    _ selector: AudioObjectPropertySelector, element: AudioObjectPropertyElement
  ) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(
      mSelector: selector, mScope: kAudioDevicePropertyScopeOutput, mElement: element)
  }

  private func settableAddress(
    _ device: AudioDeviceID, selector: AudioObjectPropertySelector,
    element: AudioObjectPropertyElement
  ) -> AudioObjectPropertyAddress? {
    var address = address(selector, element: element)
    var settable = DarwinBoolean(false)
    guard AudioObjectHasProperty(device, &address),
      AudioObjectIsPropertySettable(device, &address, &settable) == noErr,
      settable.boolValue
    else { return nil }
    return address
  }
}

enum OutputRestorePolicy {
  static func matches(_ lhs: Float32, _ rhs: Float32) -> Bool {
    abs(lhs - rhs) < 0.0001
  }

  static func shouldRestore(current: Float32, applied: Float32) -> Bool {
    matches(current, applied)
  }
}

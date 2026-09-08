import CoreAudio
import Darwin
import Foundation
import IOKit.ps

enum DiagnosticsClock {
  static let timebase: mach_timebase_info_data_t = {
    var value = mach_timebase_info_data_t()
    mach_timebase_info(&value)
    return value
  }()

  static func milliseconds(_ ticks: UInt64, numer: UInt32, denom: UInt32) -> Double {
    guard denom > 0 else { return 0 }
    return Double(ticks) * Double(numer) / Double(denom) / 1_000_000
  }

  static func milliseconds(_ ticks: UInt64) -> Double {
    milliseconds(ticks, numer: timebase.numer, denom: timebase.denom)
  }

  /// Continuous time includes sleep; interval baselines are reset at sleep/wake.
  static func uptimeMS() -> Double { milliseconds(mach_continuous_time()) }
}

struct ProcessResourceSnapshot: Codable, Equatable, Sendable {
  let sampledAt: Date
  let uptimeMS: Double
  let userCPUMS: Double
  let systemCPUMS: Double
  let physicalFootprintBytes: UInt64
  let lifetimePeakFootprintBytes: UInt64
  let diskReadBytes: UInt64
  let diskWriteBytes: UInt64
  let idleWakeups: UInt64
  let interruptWakeups: UInt64
  let thermalState: String
  let lowPowerMode: Bool
  let powerSource: String
}

struct ResourceInterval: Codable, Equatable, Sendable {
  let elapsedMS: Double
  let cpuMS: Double
  /// 100% means one fully occupied logical CPU, not the whole machine.
  let averageCPUPercent: Double
  let diskReadBytes: UInt64
  let diskWriteBytes: UInt64
  let idleWakeups: UInt64
  let interruptWakeups: UInt64

  init?(from previous: ProcessResourceSnapshot, to current: ProcessResourceSnapshot) {
    let elapsed = current.uptimeMS - previous.uptimeMS
    guard elapsed > 0, current.userCPUMS >= previous.userCPUMS,
      current.systemCPUMS >= previous.systemCPUMS,
      current.diskReadBytes >= previous.diskReadBytes,
      current.diskWriteBytes >= previous.diskWriteBytes,
      current.idleWakeups >= previous.idleWakeups,
      current.interruptWakeups >= previous.interruptWakeups
    else { return nil }
    elapsedMS = elapsed
    cpuMS = current.userCPUMS - previous.userCPUMS + current.systemCPUMS - previous.systemCPUMS
    averageCPUPercent = cpuMS / elapsed * 100
    diskReadBytes = current.diskReadBytes - previous.diskReadBytes
    diskWriteBytes = current.diskWriteBytes - previous.diskWriteBytes
    idleWakeups = current.idleWakeups - previous.idleWakeups
    interruptWakeups = current.interruptWakeups - previous.interruptWakeups
  }
}

protocol ResourceSampling: Sendable {
  func sample() -> ProcessResourceSnapshot?
}

struct ProcessResourceSampler: ResourceSampling {
  func sample() -> ProcessResourceSnapshot? {
    guard let value = Self.usage(for: getpid()) else { return nil }
    let sampledAt = Date()
    let uptimeMS = DiagnosticsClock.uptimeMS()
    let info = ProcessInfo.processInfo
    let thermal: String
    switch info.thermalState {
    case .nominal: thermal = "nominal"
    case .fair: thermal = "fair"
    case .serious: thermal = "serious"
    case .critical: thermal = "critical"
    @unknown default: thermal = "unknown"
    }
    let power: String
    if let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
      let source = IOPSGetProvidingPowerSourceType(blob)?.takeUnretainedValue() {
      switch source as String {
      case kIOPSACPowerValue: power = "ac"
      case kIOPSBatteryPowerValue: power = "battery"
      default: power = "unknown"
      }
    } else { power = "unknown" }
    return ProcessResourceSnapshot(
      sampledAt: sampledAt, uptimeMS: uptimeMS,
      userCPUMS: DiagnosticsClock.milliseconds(value.ri_user_time),
      systemCPUMS: DiagnosticsClock.milliseconds(value.ri_system_time),
      physicalFootprintBytes: value.ri_phys_footprint,
      lifetimePeakFootprintBytes: value.ri_lifetime_max_phys_footprint,
      diskReadBytes: value.ri_diskio_bytesread, diskWriteBytes: value.ri_diskio_byteswritten,
      idleWakeups: value.ri_pkg_idle_wkups, interruptWakeups: value.ri_interrupt_wkups,
      thermalState: thermal, lowPowerMode: info.isLowPowerModeEnabled, powerSource: power)
  }

  static func usage(for pid: pid_t) -> rusage_info_v4? {
    var value = rusage_info_v4()
    let result = withUnsafeMutablePointer(to: &value) { pointer in
      pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
        proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
      }
    }
    return result == 0 ? value : nil
  }

  static var executableUUID: String? {
    guard let value = usage(for: getpid()) else { return nil }
    let uuid = UUID(uuid: value.ri_uuid)
    guard uuid != UUID(uuidString: "00000000-0000-0000-0000-000000000000") else { return nil }
    return uuid.uuidString
  }

  static var hardwareModel: String? {
    var size = 0
    guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return nil }
    var bytes = [CChar](repeating: 0, count: size)
    guard sysctlbyname("hw.model", &bytes, &size, nil, 0) == 0 else { return nil }
    return String(bytes: bytes.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, encoding: .utf8)
  }
}

struct DiagnosticAudioRoute: Codable, Equatable, Sendable {
  let transport: String
  let sampleRate: Double
  let channels: UInt32

  /// Only called away from the main/audio callback threads. Device IDs never leave this method.
  static func current() -> Self? {
    guard let route = AudioInputRoute.current() else { return nil }
    var type: UInt32 = 0
    var size = UInt32(MemoryLayout.size(ofValue: type))
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyTransportType, mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    let status = AudioObjectGetPropertyData(route.deviceID, &address, 0, nil, &size, &type)
    let transport: String
    switch status == noErr ? type : 0 {
    case kAudioDeviceTransportTypeBuiltIn: transport = "builtIn"
    case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: transport = "bluetooth"
    case kAudioDeviceTransportTypeUSB: transport = "usb"
    case 0: transport = "unknown"
    default: transport = "other"
    }
    return Self(transport: transport, sampleRate: route.sampleRate, channels: route.channels)
  }
}

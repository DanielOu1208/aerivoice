#!/usr/bin/env swift
import Foundation
import AppKit
import Darwin
import CryptoKit

typealias JSONObject = [String: Any]
struct RecorderError: Error, CustomStringConvertible {
  let description: String
  init(_ description: String) { self.description = description }
}
let bundleID = "com.danielou.AeriVoice"
let fm = FileManager.default
let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
let dateFormatter = ISO8601DateFormatter()
let fractionalFormatter: ISO8601DateFormatter = {
  let formatter = ISO8601DateFormatter()
  formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  return formatter
}()
func timestamp(_ date: Date = Date()) -> String { fractionalFormatter.string(from: date) }
func date(_ value: Any?) -> Date? {
  guard let text = value as? String else { return nil }
  return fractionalFormatter.date(from: text) ?? dateFormatter.date(from: text)
}
func object(_ value: Any?) -> JSONObject { value as? JSONObject ?? [:] }
func ticksMS(_ ticks: UInt64) -> Double {
  var timebase = mach_timebase_info_data_t()
  mach_timebase_info(&timebase)
  return Double(ticks) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000
}
struct Options {
  var mode = "idle"
  var pid: pid_t?
  var duration: Double = 300
  var count = 10
  var output: URL?
  static func parse(_ args: [String]) throws -> Options {
    var result = Options()
    var duration: Double?
    var index = 0
    var seen = Set<String>()
    while index < args.count {
      let flag = args[index]
      guard seen.insert(flag).inserted, index + 1 < args.count else {
        throw RecorderError("Missing value or duplicate option: \(flag)")
      }
      let value = args[index + 1]
      switch flag {
      case "--mode":
        guard ["idle", "dictation"].contains(value) else { throw RecorderError("Invalid mode") }
        result.mode = value
      case "--pid":
        guard let pid = Int32(value), pid > 0 else { throw RecorderError("Invalid PID") }
        result.pid = pid
      case "--duration":
        guard let seconds = Double(value), seconds.isFinite, seconds > 0 else {
          throw RecorderError("Duration must be a positive finite number")
        }
        duration = seconds
      case "--count":
        guard let count = Int(value), count > 0 else { throw RecorderError("Count must be positive") }
        result.count = count
      case "--output": result.output = URL(fileURLWithPath: NSString(string: value).expandingTildeInPath)
      default: throw RecorderError("Unknown option: \(flag)")
      }
      index += 2
    }
    result.duration = duration ?? (result.mode == "idle" ? 300 : 900)
    return result
  }
}

func isMissingFile(_ error: Error) -> Bool {
  let error = error as NSError
  return (error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT))
    || (error.domain == NSCocoaErrorDomain
      && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code))
}

// Track each inode across renames. Incomplete JSON stays buffered until its newline
// arrives; historical bytes are never reread per poll and only one descriptor is open.
final class LogTail {
  final class Cursor {
    var offset: UInt64 = 0
    var pending = Data()
  }
  let directory: URL
  let prefix: String
  var cursors: [String: Cursor] = [:]
  var malformedLines = 0
  private let openFile: (URL) throws -> FileHandle
  init(_ directory: URL, _ prefix: String,
    openFile: @escaping (URL) throws -> FileHandle = { try FileHandle(forReadingFrom: $0) }) {
    self.directory = directory
    self.prefix = prefix
    self.openFile = openFile
  }
  func poll(_ visit: (JSONObject) throws -> Void) throws {
    // Retry discovery once immediately, including on the very first collection poll.
    if try pollPass(visit) { _ = try pollPass(visit) }
  }
  private func pollPass(_ visit: (JSONObject) throws -> Void) throws -> Bool {
    let current = directory.appendingPathComponent("\(prefix).jsonl")
    let archives = directory.appendingPathComponent("Archives")
    let archived: [URL]
    do { archived = try fm.contentsOfDirectory(at: archives, includingPropertiesForKeys: nil) }
    catch where isMissingFile(error) { archived = [] }
    let files = archived.filter {
      $0.lastPathComponent.hasPrefix(prefix + "-") && $0.pathExtension == "jsonl"
    }.sorted { $0.lastPathComponent < $1.lastPathComponent } + [current]
    var visited = Set<String>()
    var missingPath = false
    for url in files {
      let handle: FileHandle
      do { handle = try openFile(url) }
      // Rotation and pruning can remove a listed path between enumeration and open.
      catch where isMissingFile(error) { missingPath = true; continue }
      defer { try? handle.close() }
      var attrs = stat()
      guard fstat(handle.fileDescriptor, &attrs) == 0 else { throw RecorderError("Cannot inspect log identity") }
      let identity = "\(attrs.st_dev):\(attrs.st_ino)"
      guard visited.insert(identity).inserted else { continue }
      let cursor = cursors[identity] ?? Cursor()
      cursors[identity] = cursor
      let size = try handle.seekToEnd()
      if size < cursor.offset { cursor.offset = 0; cursor.pending.removeAll() }
      try handle.seek(toOffset: cursor.offset)
      while let chunk = try handle.read(upToCount: 65_536), !chunk.isEmpty {
        cursor.offset += UInt64(chunk.count)
        cursor.pending.append(chunk)
        while let newline = cursor.pending.firstIndex(of: 0x0A) {
          let line = cursor.pending.prefix(upTo: newline)
          if !line.isEmpty {
            try autoreleasepool {
              if let record = try? JSONSerialization.jsonObject(with: Data(line)) as? JSONObject {
                try visit(record)
              } else { malformedLines += 1 }
            }
          }
          cursor.pending.removeSubrange(...newline)
        }
        guard cursor.pending.count <= 4 * 1_024 * 1_024 else {
          throw RecorderError("Log line exceeds 4 MiB; collection stopped")
        }
      }
    }
    return missingPath
  }
}
struct Identity: Equatable {
  let uuid: String
  let startTicks: UInt64
  init(_ usage: rusage_info_v4) {
    uuid = UUID(uuid: usage.ri_uuid).uuidString
    startTicks = usage.ri_proc_start_abstime
  }
}
func usage(_ pid: pid_t) throws -> rusage_info_v4 {
  var result = rusage_info_v4()
  let status = withUnsafeMutablePointer(to: &result) { pointer in
    pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
      proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
    }
  }
  guard status == 0 else { throw RecorderError("Process resource read failed (errno \(errno)); app may have exited") }
  return result
}
func checkedUsage(expected: Identity, read: () throws -> rusage_info_v4) throws -> rusage_info_v4 {
  let result = try read()
  guard Identity(result) == expected else { throw RecorderError("Target exited or process identity changed") }
  return result
}
func executablePath(_ pid: pid_t) throws -> String {
  var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
  let count = proc_pidpath(pid, &buffer, UInt32(buffer.count))
  guard count > 0 else { throw RecorderError("Cannot resolve target executable") }
  return String(cString: buffer)
}
func sha256(_ url: URL) throws -> String {
  let file = try FileHandle(forReadingFrom: url)
  defer { try? file.close() }
  var hash = SHA256()
  while let chunk = try file.read(upToCount: 1_048_576), !chunk.isEmpty { hash.update(data: chunk) }
  return hash.finalize().map { String(format: "%02x", $0) }.joined()
}
func verifyExecutableUUID(_ url: URL, expected: String) throws {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/dwarfdump")
  process.arguments = ["--uuid", url.path]
  let output = Pipe()
  process.standardOutput = output
  process.standardError = FileHandle.nullDevice
  try process.run()
  let data = output.fileHandleForReading.readDataToEndOfFile()
  process.waitUntilExit()
  let matches = String(decoding: data, as: UTF8.self).split(separator: "\n").contains { line in
    let fields = line.split(separator: " ")
    return fields.count >= 2 && fields[0] == "UUID:" && fields[1].uppercased() == expected.uppercased()
  }
  guard process.terminationStatus == 0, matches else {
    throw RecorderError("On-disk executable does not match the running build UUID; relaunch the intended build before recording")
  }
}
func createPrivateDirectory(_ url: URL) throws {
  guard !fm.fileExists(atPath: url.path) else { throw RecorderError("Output already exists; refusing overwrite") }
  try fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
  try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
}
func writeJSON(_ record: JSONObject, to url: URL) throws {
  let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys, .prettyPrinted])
  try data.write(to: url, options: .atomic)
  try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
}
final class JSONLines {
  let handle: FileHandle
  private(set) var recordCount = 0
  init(_ url: URL) throws {
    guard fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
      throw RecorderError("Cannot create output file")
    }
    handle = try FileHandle(forWritingTo: url)
  }
  func append(_ record: JSONObject) throws {
    var data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
    data.append(0x0A)
    try handle.write(contentsOf: data)
    recordCount += 1
  }
  deinit { try? handle.close() }
}
func matchesRuntime(_ record: JSONObject, pid: pid_t, uuid: String, launchDate: Date) -> Bool {
  (record["schemaVersion"] as? Int) == 1 && (record["processID"] as? NSNumber)?.int32Value == pid
    && (object(record["environment"])["executableUUID"] as? String)?.uppercased() == uuid.uppercased()
    && (date(record["recordedAt"]) ?? .distantPast) >= launchDate
    && record["launchID"] is String
}
// A millisecond wall timestamp can tie across transitions; uptime retains their order.
func runtimePrecedes(_ lhs: JSONObject, _ rhs: JSONObject) -> Bool {
  let leftDate = date(lhs["recordedAt"]) ?? .distantPast
  let rightDate = date(rhs["recordedAt"]) ?? .distantPast
  if leftDate != rightDate { return leftDate < rightDate }
  return (lhs["uptimeMS"] as? Double ?? 0) < (rhs["uptimeMS"] as? Double ?? 0)
}
func runtimeUnavailableReason(_ record: JSONObject?, at now: Date) -> String? {
  guard let record else {
    return "No matching runtime records. Use a build with runtime logging enabled; idle state and guided attempts cannot be verified"
  }
  if ["loggingDisabled", "termination"].contains(record["event"] as? String ?? "") {
    return "Runtime logging unavailable: \(record["event"] ?? "unknown")"
  }
  guard let recordedAt = date(record["recordedAt"]), now.timeIntervalSince(recordedAt) <= 360 else {
    return "Runtime context is older than the 360-second heartbeat allowance"
  }
  return nil
}
func matchesInteraction(_ record: JSONObject, launchID: String, started: Date) -> Bool {
  record["schemaVersion"] as? Int == 1
    && object(record["context"])["launchID"] as? String == launchID
    && (date(record["startedAt"]) ?? .distantPast) >= started
    && (date(record["endedAt"]) ?? .distantPast) >= started
    && object(record["outcome"])["terminalResult"] is String
    && record["interactionID"] is String
}
func intervalActivity(_ baseline: JSONObject?, _ records: [JSONObject], at now: Date = Date()) -> String {
  guard let baseline, baseline["activity"] as? String == "idle",
    let baselineDate = date(baseline["recordedAt"]), now.timeIntervalSince(baselineDate) <= 360,
    let generation = baseline["activityGeneration"] as? String else { return "unknown" }
  return records.allSatisfy {
    $0["activity"] as? String == "idle" && $0["activityGeneration"] as? String == generation
      && $0["launchID"] as? String == baseline["launchID"] as? String
      && ($0["droppedWrites"] as? Int ?? 0) == (baseline["droppedWrites"] as? Int ?? 0)
      && !["loggingDisabled", "termination"].contains($0["event"] as? String ?? "")
  } ? "observed_idle" : "unknown"
}
func safeSettings(_ value: Any?) -> JSONObject {
  let input = object(value)
  let strings = ["transcriptionProvider", "cleanupProvider", "cleanupModel", "cleanupMode", "reasoningEffort", "activationMode"]
  let booleans = ["soundCues", "muteOutput", "onboardingComplete"]
  var result: JSONObject = [:]
  for key in strings { if let value = input[key] as? String { result[key] = value } }
  for key in booleans { if let value = input[key] as? Bool { result[key] = value } }
  return result
}
func partialManifest(_ manifest: JSONObject, status: String, reason: String, count: Int) -> JSONObject {
  var result = manifest
  result["collectionEndedAt"] = timestamp()
  result["status"] = status
  result["complete"] = status == "complete"
  result["reason"] = reason
  result["terminalAttemptCount"] = count
  return result
}

func run(_ options: Options) throws -> Int32 {
  umask(0o077)
  let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
    .filter { options.pid == nil || $0.processIdentifier == options.pid }
  guard apps.count == 1, let app = apps.first, let executable = app.executableURL,
    let bundleURL = app.bundleURL, let launchDate = app.launchDate else {
    throw RecorderError("Expected exactly one running AeriVoice target with a known launch date; found \(apps.count)")
  }
  let pid = app.processIdentifier
  let initialUsage = try usage(pid)
  let identity = Identity(initialUsage)
  let path = try executablePath(pid)
  guard path == executable.path else { throw RecorderError("Running executable path does not match app bundle") }
  let infoURL = bundleURL.appendingPathComponent("Contents/Info.plist")
  let info = NSDictionary(contentsOf: infoURL) as? JSONObject ?? [:]
  try verifyExecutableUUID(executable, expected: identity.uuid)
  let executableHash = try sha256(executable)
  let initialAttrs = try fm.attributesOfItem(atPath: path)
  let initialInfo = try Data(contentsOf: infoURL)
  let started = Date()
  let startTicks = mach_continuous_time()
  let runID = UUID().uuidString
  let output = options.output ?? support.appendingPathComponent("AeriVoice/BenchmarkRuns")
    .appendingPathComponent("\(timestamp(started).replacingOccurrences(of: ":", with: "-"))-\(runID)")
  try createPrivateDirectory(output)
  var manifest: JSONObject = [
    "formatVersion": 1, "runID": runID, "mode": options.mode,
    "bundleIdentifier": bundleID, "appVersion": info["CFBundleShortVersionString"] ?? NSNull(),
    "appBuild": info["CFBundleVersion"] ?? NSNull(), "executableUUID": identity.uuid,
    "executableSHA256": executableHash, "processID": pid,
    "processStart": ["wallTime": timestamp(launchDate), "machAbsoluteTicks": identity.startTicks],
    "requestedDurationSeconds": options.duration, "requestedCount": options.count,
    "collectionStartedAt": timestamp(started), "collectionStartedContinuousMS": ticksMS(startTicks),
    "status": "collecting", "complete": false,
  ]
  let manifestURL = output.appendingPathComponent("manifest.json")
  try writeJSON(manifest, to: manifestURL)
  let resourceOutput = try JSONLines(output.appendingPathComponent("resources-v1.jsonl"))
  let runtimeOutput = try JSONLines(output.appendingPathComponent("runtime-v1.jsonl"))
  let interactionOutput = try JSONLines(output.appendingPathComponent("interactions-v1.jsonl"))
  let logs = support.appendingPathComponent("AeriVoice/Benchmarks")
  let runtimeTail = LogTail(logs, "runtime-v1")
  let interactionTail = LogTail(logs, "interactions-v1")
  var runtimeIDs = Set<String>()
  var interactionIDs = Set<String>()
  var latest: JSONObject?
  var status = "partial"
  var reason = "Collection interrupted"
  var interrupted = false
  signal(SIGINT, SIG_IGN)
  signal(SIGTERM, SIG_IGN)
  let signalQueue = DispatchQueue(label: "performance-recorder.signals")
  let lock = NSLock()
  let sources = [SIGINT, SIGTERM].map { value -> DispatchSourceSignal in
    let source = DispatchSource.makeSignalSource(signal: value, queue: signalQueue)
    source.setEventHandler { lock.lock(); interrupted = true; lock.unlock() }
    source.resume()
    return source
  }
  defer { sources.forEach { $0.cancel() } }
  print("Recording \(options.mode) to \(output.path)")
  if options.mode == "dictation" {
    print("Choose your own safe text destination. Trigger AeriVoice normally and say:")
    print("The quick brown fox jumps over the lazy dog. Please send the meeting notes tomorrow morning.")
    print("Repeat for \(options.count) attempts. Failed and cancelled attempts also count. Ctrl-C saves a partial run.")
  }
  var first = true
  do {
    while true {
      let currentUsage = try checkedUsage(expected: identity) { try usage(pid) }
      let sampledAt = Date()
      let sampledTicks = mach_continuous_time()
      guard try executablePath(pid) == path else {
        throw RecorderError("Target exited or process identity changed")
      }
      let attrs = try fm.attributesOfItem(atPath: path)
      guard (attrs[.systemFileNumber] as? NSNumber) == (initialAttrs[.systemFileNumber] as? NSNumber),
        (attrs[.size] as? NSNumber) == (initialAttrs[.size] as? NSNumber),
        (attrs[.modificationDate] as? Date) == (initialAttrs[.modificationDate] as? Date),
        try Data(contentsOf: infoURL) == initialInfo else {
        throw RecorderError("Target executable or build changed during collection")
      }
      let preceding = latest
      var baseline: JSONObject?
      var classification = first ? "unknown" : intervalActivity(preceding, [])
      try runtimeTail.poll { record in
        guard matchesRuntime(record, pid: pid, uuid: identity.uuid, launchDate: launchDate) else { return }
        let recordedAt = date(record["recordedAt"]) ?? .distantPast
        if first, recordedAt <= started,
          baseline == nil || runtimePrecedes(baseline!, record) { baseline = record }
        if latest == nil || runtimePrecedes(latest!, record) { latest = record }
        guard recordedAt >= started else { return }
        if classification != "unknown", intervalActivity(preceding, [record]) == "unknown" {
          classification = "unknown"
        }
        if let id = record["recordID"] as? String, runtimeIDs.insert(id).inserted {
          try runtimeOutput.append(record)
        }
      }
      if first, let baseline {
        manifest["baselineRuntimeRecordID"] = baseline["recordID"]
        manifest["settings"] = safeSettings(baseline["settings"])
        if let id = baseline["recordID"] as? String, runtimeIDs.insert(id).inserted {
          try runtimeOutput.append(baseline)
        }
      }
      let nowTicks = sampledTicks
      try resourceOutput.append([
        "schemaVersion": 1, "runID": runID, "recordedAt": timestamp(sampledAt),
        "continuousMS": ticksMS(nowTicks), "elapsedMS": ticksMS(nowTicks - startTicks),
        "processID": pid, "executableUUID": identity.uuid,
        "processStartMachAbsoluteTicks": identity.startTicks, "precedingIntervalActivity": classification,
        "userCPUMS": ticksMS(currentUsage.ri_user_time), "systemCPUMS": ticksMS(currentUsage.ri_system_time),
        "physicalFootprintBytes": currentUsage.ri_phys_footprint,
        "lifetimePeakPhysicalFootprintBytes": currentUsage.ri_lifetime_max_phys_footprint,
        "diskReadBytes": currentUsage.ri_diskio_bytesread, "diskWriteBytes": currentUsage.ri_diskio_byteswritten,
        "interruptWakeups": currentUsage.ri_interrupt_wkups, "platformIdleWakeups": currentUsage.ri_pkg_idle_wkups,
      ])
      if let unavailable = runtimeUnavailableReason(latest, at: Date()) { throw RecorderError(unavailable) }
      guard let current = latest, let launchID = current["launchID"] as? String else {
        throw RecorderError("Runtime record has no launch identity")
      }
      manifest["launchID"] = launchID
      if manifest["settings"] == nil { manifest["settings"] = safeSettings(current["settings"]) }
      try interactionTail.poll { record in
        guard matchesInteraction(record, launchID: launchID, started: started),
          let id = record["interactionID"] as? String, interactionIDs.insert(id).inserted else { return }
        try interactionOutput.append(record)
        if options.mode == "dictation" { print("Completed attempts: \(interactionIDs.count)/\(options.count)") }
      }
      lock.lock(); let shouldStop = interrupted; lock.unlock()
      if shouldStop { reason = "Interrupted by signal"; break }
      if options.mode == "dictation", interactionIDs.count >= options.count {
        status = "complete"; reason = "Requested terminal attempts collected"; break
      }
      if ticksMS(nowTicks - startTicks) >= options.duration * 1_000 {
        if options.mode == "idle" { status = "complete"; reason = "Requested duration collected" }
        else { reason = "Timed out before requested terminal attempt count" }
        break
      }
      first = false
      Thread.sleep(forTimeInterval: min(1, max(0.01, options.duration - ticksMS(mach_continuous_time() - startTicks) / 1_000)))
    }
  } catch { reason = String(describing: error) }
  if (try? sha256(executable)) != executableHash {
    status = "partial"; reason = "Executable hash changed or became unreadable during collection"
  }
  manifest["resourceSampleCount"] = resourceOutput.recordCount
  manifest["runtimeRecordCount"] = runtimeOutput.recordCount
  if let latest { manifest["environment"] = object(latest["environment"]) }
  manifest["malformedRuntimeLines"] = runtimeTail.malformedLines
  manifest["malformedInteractionLines"] = interactionTail.malformedLines
  manifest = partialManifest(manifest, status: status, reason: reason, count: interactionIDs.count)
  try writeJSON(manifest, to: manifestURL)
  print("\(status): \(reason)")
  return status == "complete" ? 0 : 2
}

func selfTest() throws {
  func check(_ value: @autoclosure () throws -> Bool, _ name: String) throws {
    guard try value() else { throw RecorderError("Fixture failed: \(name)") }
  }
  let directory = fm.temporaryDirectory.appendingPathComponent("aerivoice-recorder-fixture-\(UUID().uuidString)")
  try createPrivateDirectory(directory)
  defer { try? fm.removeItem(at: directory) }
  let file = directory.appendingPathComponent("runtime-v1.jsonl")
  try Data("{\"recordID\":\"a\"}\n{\"recordID\":".utf8).write(to: file)
  let tail = LogTail(directory, "runtime-v1")
  var initial: [JSONObject] = []
  try tail.poll { initial.append($0) }
  try check(initial.count == 1, "partial line withheld")
  let handle = try FileHandle(forWritingTo: file)
  try handle.seekToEnd(); try handle.write(contentsOf: Data("\"b\"}\n".utf8)); try handle.close()
  var completed: [JSONObject] = []
  try tail.poll { completed.append($0) }
  try check(completed.count == 1 && completed[0]["recordID"] as? String == "b", "partial line completed")
  let archives = directory.appendingPathComponent("Archives")
  try fm.createDirectory(at: archives, withIntermediateDirectories: false)
  try fm.moveItem(at: file, to: archives.appendingPathComponent("runtime-v1-fixture.jsonl"))
  try Data("{\"recordID\":\"c\"}\n".utf8).write(to: file)
  var rotated = 0
  try tail.poll { _ in rotated += 1 }
  try check(rotated == 1, "rotation does not reread archive")
  let largeFile = directory.appendingPathComponent("interactions-v1.jsonl")
  let largeOutput = try JSONLines(largeFile)
  for index in 0..<5_000 { try largeOutput.append(["interactionID": "fixture-\(index)"]) }
  let largeTail = LogTail(directory, "interactions-v1")
  var streamedCount = 0
  try largeTail.poll { _ in streamedCount += 1 }
  try check(streamedCount == 5_000, "history visits incrementally without accumulating records")
  try largeTail.poll { _ in streamedCount += 1 }
  try check(streamedCount == 5_000, "history not reread on next poll")
  let raceDirectory = directory.appendingPathComponent("rotation-race")
  let raceArchives = raceDirectory.appendingPathComponent("Archives")
  try fm.createDirectory(at: raceArchives, withIntermediateDirectories: true)
  let raceFile = raceDirectory.appendingPathComponent("runtime-v1.jsonl")
  try Data("{\"recordID\":\"raced\"}\n".utf8).write(to: raceFile)
  var didRotate = false
  let racingTail = LogTail(raceDirectory, "runtime-v1", openFile: { url in
    if url == raceFile && !didRotate {
      didRotate = true
      try fm.moveItem(at: raceFile, to: raceArchives.appendingPathComponent("runtime-v1-raced.jsonl"))
    }
    return try FileHandle(forReadingFrom: url)
  })
  var raceCount = 0
  try racingTail.poll { _ in raceCount += 1 }
  try check(raceCount == 1 && didRotate, "first poll rediscovers rotated file before runtime validation")
  try racingTail.poll { _ in raceCount += 1 }
  try check(raceCount == 1, "rediscovered inode not duplicated next poll")
  let deniedTail = LogTail(raceDirectory, "runtime-v1", openFile: { _ in
    throw NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
  })
  var preservedReadError = false
  do { try deniedTail.poll { _ in } }
  catch { preservedReadError = (error as NSError).code == Int(EACCES) }
  try check(preservedReadError, "other read failures propagate")
  try check(largeOutput.recordCount == 5_000, "output record count tracks successful writes")
  var resource = rusage_info_v4()
  resource.ri_proc_start_abstime = 12
  let original = Identity(resource)
  resource.ri_proc_start_abstime = 13
  try check(original != Identity(resource), "PID reuse changes identity")
  resource.ri_proc_start_abstime = 12
  resource.ri_uuid.0 = 1
  try check(original != Identity(resource), "UUID change changes identity")
  let launched = Date(timeIntervalSince1970: 100)
  let record: JSONObject = ["schemaVersion": 1, "processID": 42, "environment": ["executableUUID": "A"],
    "recordedAt": timestamp(launched), "launchID": "launch", "activity": "idle", "activityGeneration": "generation-1"]
  try check(matchesRuntime(record, pid: 42, uuid: "A", launchDate: launched), "matching runtime")
  try check(!matchesRuntime(record, pid: 42, uuid: "A", launchDate: launched.addingTimeInterval(1)), "past launch rejected")
  try check(!matchesRuntime(record, pid: 43, uuid: "A", launchDate: launched), "wrong PID rejected")
  var later = record; later["uptimeMS"] = 2.0
  var earlier = record; earlier["uptimeMS"] = 1.0
  try check(runtimePrecedes(earlier, later) && !runtimePrecedes(later, earlier), "uptime breaks timestamp ties")
  var disabled = record; disabled["event"] = "loggingDisabled"
  try check(runtimeUnavailableReason(disabled, at: launched) != nil, "disabled logging stops collection")
  try check(runtimeUnavailableReason(nil, at: launched) != nil, "missing runtime stops collection")
  var terminated = record; terminated["event"] = "termination"
  try check(runtimeUnavailableReason(terminated, at: launched) != nil, "termination stops collection")
  var failureReason: String?
  do {
    _ = try checkedUsage(expected: original) { throw RecorderError("fixture process disappeared") }
  } catch { failureReason = String(describing: error) }
  try check(failureReason == "fixture process disappeared", "disappearance does not become zero resources")
  let disappeared = partialManifest([:], status: "partial", reason: failureReason ?? "", count: 0)
  try check(disappeared["complete"] as? Bool == false, "process disappearance produces partial metadata")
  let attempt: JSONObject = ["schemaVersion": 1, "interactionID": "attempt", "context": ["launchID": "launch"],
    "startedAt": timestamp(launched), "endedAt": timestamp(launched), "outcome": ["terminalResult": "cancelled"]]
  try check(matchesInteraction(attempt, launchID: "launch", started: launched), "cancelled attempts count")
  try check(!matchesInteraction(attempt, launchID: "foreign", started: launched), "foreign launch rejected")
  try check(!matchesInteraction(attempt, launchID: "launch", started: launched.addingTimeInterval(1)), "historical attempt rejected")
  try check(intervalActivity(nil, []) == "unknown", "no baseline is unknown")
  var changed = record; changed["activityGeneration"] = "generation-2"
  try check(intervalActivity(record, [changed], at: launched) == "unknown", "transition invalidates idle")
  try check(intervalActivity(record, [record], at: launched) == "observed_idle", "stable idle")
  try check(intervalActivity(record, [], at: launched.addingTimeInterval(361)) == "unknown", "stale baseline unknown")
  var dropped = record; dropped["droppedWrites"] = 1
  try check(intervalActivity(record, [dropped], at: launched) == "unknown", "dropped events invalidate interval")
  try check(safeSettings(["soundCues": true, "vocabulary": "private"])["vocabulary"] == nil, "settings allowlist")
  let partial = partialManifest(["runID": "fixture"], status: "partial", reason: "Timed out", count: 2)
  try check(partial["complete"] as? Bool == false && partial["terminalAttemptCount"] as? Int == 2, "partial manifest")
  let partialURL = directory.appendingPathComponent("manifest.json")
  try writeJSON(partial, to: partialURL)
  let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: partialURL)) as? JSONObject
  try check(saved?["reason"] as? String == "Timed out", "partial manifest persisted")
  let permissions = try fm.attributesOfItem(atPath: partialURL.path)[.posixPermissions] as? NSNumber
  try check(permissions?.intValue == 0o600, "private output permissions")
  try check(try Options.parse(["--mode", "dictation"]).duration == 900, "dictation default timeout")
  print("All recorder fixture tests passed")
}
let arguments = Array(CommandLine.arguments.dropFirst())
if arguments == ["--help"] || arguments == ["-h"] {
  print("""
  Usage: xcrun swift scripts/record-performance.swift [--mode idle|dictation] [--pid PID]
         [--duration SECONDS] [--count ATTEMPTS] [--output NEW_DIRECTORY]
  Idle defaults to 300 seconds; dictation waits up to 900 seconds for 10 terminal attempts.
  Without --pid exactly one running com.danielou.AeriVoice app is required.
  Idle labels mean observed idle from runtime events, not guaranteed app quiescence.
  Writes private manifest.json, resources-v1.jsonl, runtime-v1.jsonl and interactions-v1.jsonl.
  Output must not already exist. No app activation, key presses, or network requests are performed.
  Ctrl-C, app exit, and dictation timeout save partial results (exit code 2).
  --self-test runs only temporary local fixtures, without accessing the app or its logs.
  """)
} else {
  do {
    if arguments == ["--self-test"] { try selfTest() }
    else { exit(try run(Options.parse(arguments))) }
  } catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8)); exit(1)
  }
}

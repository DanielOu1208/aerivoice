import Darwin
import Foundation

/// Serializes local diagnostics. Readers and retention scans never hold a whole log in memory.
actor LatencyBenchmarkStore {
  static let logFilename = "interactions-v1.jsonl"
  static let runtimeFilename = "runtime-v1.jsonl"
  static let activeFilename = "active-interaction-v1.json"
  static let retentionDays = 365
  static var defaultDirectoryURL: URL {
    AppStoragePaths.applicationSupport.appending(path: "Benchmarks", directoryHint: .isDirectory)
  }

  let directoryURL: URL
  private let fileManager: FileManager
  private let rotationBytes: Int
  private let maxTotalBytes: Int
  private let retentionDays: Int
  private let encoder = DiagnosticsJSON.encoder()
  private let decoder = DiagnosticsJSON.decoder()
  private var lastAgeScan: Date?
  private var segmentDays: [String: Int] = [:]
  private var archivesURL: URL { directoryURL.appending(path: "Archives") }

  init(directoryURL: URL, fileManager: FileManager = .default,
       rotationBytes: Int = 8_000_000, maxTotalBytes: Int = 200_000_000,
       retentionDays: Int = 365) {
    self.directoryURL = directoryURL
    self.fileManager = fileManager
    self.rotationBytes = max(1, rotationBytes)
    self.maxTotalBytes = max(0, maxTotalBytes)
    self.retentionDays = max(0, retentionDays)
  }

  func checkpoint(_ record: LatencyBenchmarkRecord) throws {
    try prepareDirectory()
    try atomicWrite(encoder.encode(record), to: directoryURL.appending(path: Self.activeFilename))
    try enforceCap()
  }

  /// Enforce retention after collection stops without recovering an unfinished interaction.
  func discardCheckpointAndPrune(now: Date) throws {
    guard fileManager.fileExists(atPath: directoryURL.path) else { return }
    try prepareDirectory()
    try removeRegularFile(directoryURL.appending(path: Self.activeFilename))
    try maintain(now: now)
    try enforceCap()
  }

  func complete(_ record: LatencyBenchmarkRecord, now: Date) throws {
    try prepareDirectory()
    try maintain(now: now)
    try append(encoder.encode(record), filename: Self.logFilename, now: now)
    let activeURL = directoryURL.appending(path: Self.activeFilename)
    if let data = try readSmallFile(activeURL),
       let active = try? decoder.decode(LatencyBenchmarkRecord.self, from: data),
       active.interactionID == record.interactionID {
      try removeRegularFile(activeURL)
    }
    try enforceCap()
  }

  func appendRuntime(_ data: Data, now: Date) throws {
    try prepareDirectory()
    try maintain(now: now)
    try append(data, filename: Self.runtimeFilename, now: now)
    try enforceCap()
  }

  func recoverAndPrune(now: Date, allowedGeneration: UUID? = nil,
                       acceptLegacyCheckpoint: Bool = true) throws {
    try prepareDirectory()
    let activeURL = directoryURL.appending(path: Self.activeFilename)
    if let data = try readSmallFile(activeURL),
       var record = try? decoder.decode(LatencyBenchmarkRecord.self, from: data) {
      let accepted = record.recordingGeneration.map { allowedGeneration == nil || $0 == allowedGeneration }
        ?? acceptLegacyCheckpoint
      if try accepted && !containsCompletedRecord(interactionID: record.interactionID) {
        record.milestonesMS[BenchmarkMilestone.terminal.rawValue] = record.milestonesMS.values.max() ?? 0
        record.endedAt = record.lastCheckpointAt
        record.outcome = BenchmarkOutcome(terminalResult: .interrupted, failureStage: .lifecycle,
                                         failureCategory: .unknown, httpStatus: nil)
        record.durationsMS = LatencyBenchmarkRecorder.makeDurationsForStore(from: record.milestonesMS)
        try append(encoder.encode(record), filename: Self.logFilename, now: now)
      }
    }
    // Invalid or oversized checkpoints cannot be recovered and must not persist indefinitely.
    try removeRegularFile(activeURL)
    try maintain(now: now)
    try enforceCap()
  }

  func clearCompletedHistory() throws {
    try prepareDirectory()
    for url in try completedFiles() { try removeRegularFile(url) }
    segmentDays.removeAll()
  }

  private func append(_ data: Data, filename: String, now: Date) throws {
    let url = directoryURL.appending(path: filename)
    let size = try fileSize(url)
    let day = Int(floor(now.timeIntervalSince1970 / 86_400))
    let existingDay = try segmentDays[filename] ?? Int(floor(modifiedDate(url, fallback: now).timeIntervalSince1970 / 86_400))
    if size > 0 && (size + data.count + 1 > rotationBytes || existingDay != day) {
      let stamp = Int64(try modifiedDate(url, fallback: now).timeIntervalSince1970 * 1_000)
      let archive = archivesURL.appending(path: "\(filename.dropLast(6))-\(stamp)-\(UUID().uuidString).jsonl")
      try fileManager.moveItem(at: url, to: archive)
    }
    let handle = try openFile(url, flags: O_RDWR | O_CREAT)
    defer { try? handle.close() }
    let end = try handle.seekToEnd()
    // Preserve an interrupted write as its own malformed line, never concatenate the next record.
    if end > 0 {
      try handle.seek(toOffset: end - 1)
      if try handle.read(upToCount: 1) != Data([0x0A]) {
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([0x0A]))
      }
    }
    try handle.seekToEnd()
    try handle.write(contentsOf: data)
    try handle.write(contentsOf: Data([0x0A]))
    try fileManager.setAttributes([.modificationDate: now], ofItemAtPath: url.path)
    segmentDays[filename] = day
  }

  private func containsCompletedRecord(interactionID: UUID) throws -> Bool {
    for url in try completedFiles() where url.lastPathComponent.hasPrefix("interactions-v1") {
      var found = false
      try lines(in: url) { data, _, _ in
        if let data, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let id = object["interactionID"] as? String, UUID(uuidString: id) == interactionID {
          found = true
          return false
        }
        return true
      }
      if found { return true }
    }
    return false
  }

  private func maintain(now: Date) throws {
    guard lastAgeScan.map({ now.timeIntervalSince($0) >= 86_400 }) ?? true else { return }
    let cutoff = now.addingTimeInterval(-Double(retentionDays) * 86_400)
    // Legacy files can contain records much older than their rotation timestamp.
    // Check record dates in both streams once daily, including archived segments.
    for segment in try completedSegments() where segment.info.st_size > 0 {
      try pruneSegment(segment.url, cutoff: cutoff, now: now)
    }
    lastAgeScan = now
  }

  private func pruneSegment(_ url: URL, cutoff: Date, now: Date) throws {
    let fallback = try modifiedDate(url, fallback: now)
    let temporary = directoryURL.appending(path: ".diagnostics-\(UUID().uuidString).tmp")
    var output: FileHandle?
    defer { try? output?.close(); try? removeRegularFile(temporary) }
    let source = try openFile(url, flags: O_RDONLY)
    defer { try? source.close() }
    try lines(in: url) { data, offset, length in
      var date = fallback
      if let data, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
         object["schemaVersion"] as? Int == 1 {
        for key in ["startedAt", "timestamp", "recordedAt"] {
          if let value = object[key] as? String, let parsed = DiagnosticsJSON.date(value) {
            date = parsed
            break
          }
        }
      }
      if date < cutoff {
        if output == nil {
          // Create a replacement only after finding an expired record. Unchanged
          // segments incur a bounded read but no file rewrite or timestamp change.
          let replacement = try openFile(temporary, flags: O_WRONLY | O_CREAT | O_EXCL)
          output = replacement
          try copyBytes(from: source, to: replacement, offset: 0, length: offset)
        }
      } else if let output {
        try copyBytes(from: source, to: output, offset: offset, length: length)
      }
      return true
    }
    if let output {
      let retainedBytes = try output.offset()
      try output.close()
      if retainedBytes == 0 {
        try removeRegularFile(url)
      } else {
        try replace(temporary, destination: url)
        try fileManager.setAttributes([.modificationDate: fallback], ofItemAtPath: url.path)
      }
    }
  }

  private func copyBytes(from source: FileHandle, to output: FileHandle,
                         offset: UInt64, length: UInt64) throws {
    try source.seek(toOffset: offset)
    var remaining = length
    while remaining > 0 {
      let chunk = try source.read(upToCount: Int(min(65_536, remaining))) ?? Data()
      guard !chunk.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
      try output.write(contentsOf: chunk)
      remaining -= UInt64(chunk.count)
    }
  }

  private func enforceCap() throws {
    // This runs after every write, over every segment kept: size and date come from the one
    // lstat that lists each of them.
    var files = try completedSegments().map {
      (url: $0.url, size: Int($0.info.st_size),
       date: ($0.info.st_mtimespec.tv_sec, $0.info.st_mtimespec.tv_nsec))
    }
    files.sort { $0.date == $1.date ? $0.url.path < $1.url.path : $0.date < $1.date }
    var total = try fileSize(directoryURL.appending(path: Self.activeFilename))
      + files.reduce(0) { $0 + $1.size }
    for file in files where total > maxTotalBytes {
      try removeRegularFile(file.url)
      total -= file.size
      segmentDays.removeValue(forKey: file.url.lastPathComponent)
    }
  }

  /// A line may exceed the decode bound; its offsets still allow retention to copy it in chunks.
  private func lines(in url: URL, visit: (Data?, UInt64, UInt64) throws -> Bool) throws {
    let handle = try openFile(url, flags: O_RDONLY)
    defer { try? handle.close() }
    var pending = Data()
    var oversized = false
    var offset: UInt64 = 0
    var start: UInt64 = 0
    while let chunk = try handle.read(upToCount: 65_536), !chunk.isEmpty {
      // Whole runs between newlines are copied at once; the daily scan reads all history.
      var index = chunk.startIndex
      while index < chunk.endIndex {
        let newline = chunk[index...].firstIndex(of: 0x0A)
        let end = newline ?? chunk.endIndex
        if !oversized {
          if pending.count + (end - index) <= 1_048_576 { pending.append(chunk[index..<end]) }
          else { pending.removeAll(keepingCapacity: true); oversized = true }
        }
        offset += UInt64(end - index)
        guard let newline else { break }
        offset += 1
        if try !visit(oversized ? nil : pending, start, offset - start) { return }
        pending.removeAll(keepingCapacity: true)
        oversized = false
        start = offset
        index = newline + 1
      }
    }
    if offset > start { _ = try visit(oversized ? nil : pending, start, offset - start) }
  }

  private func completedFiles() throws -> [URL] {
    try completedSegments().map(\.url)
  }

  /// Both streams' live and archived segments, each with the lstat that showed it is a
  /// regular file.
  private func completedSegments() throws -> [(url: URL, info: stat)] {
    var segments: [(url: URL, info: stat)] = []
    for url in [Self.logFilename, Self.runtimeFilename].map({ directoryURL.appending(path: $0) }) {
      if let info = try regularFileInfo(url) { segments.append((url, info)) }
    }
    for url in try fileManager.contentsOfDirectory(at: archivesURL, includingPropertiesForKeys: nil) {
      let pattern = #"^(interactions|runtime)-v1-[0-9]+-[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\.jsonl$"#
      guard url.lastPathComponent.range(of: pattern, options: .regularExpression) != nil,
        let info = try regularFileInfo(url)
      else { continue }
      segments.append((url, info))
    }
    return segments
  }

  private func prepareDirectory() throws {
    // Reject symlinks in every existing ancestor before any filesystem mutation.
    for target in [directoryURL, archivesURL] {
      var parent = target
      while parent.path != "/" {
        var info = stat()
        if lstat(parent.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFLNK {
          throw CocoaError(.fileWriteNoPermission)
        }
        parent.deleteLastPathComponent()
      }
      try fileManager.createDirectory(at: target, withIntermediateDirectories: true,
                                     attributes: [.posixPermissions: 0o700])
      try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: target.path)
    }
  }

  private func regularFile(_ url: URL) throws -> Bool {
    try regularFileInfo(url) != nil
  }

  /// nil when nothing is there; anything but a regular file is refused.
  private func regularFileInfo(_ url: URL) throws -> stat? {
    var info = stat()
    guard lstat(url.path, &info) == 0 else {
      if errno == ENOENT { return nil }
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    guard (info.st_mode & S_IFMT) == S_IFREG else { throw CocoaError(.fileWriteNoPermission) }
    return info
  }

  private func fileSize(_ url: URL) throws -> Int {
    guard try regularFile(url) else { return 0 }
    return (try fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
  }

  private func modifiedDate(_ url: URL, fallback: Date) throws -> Date {
    guard try regularFile(url) else { return fallback }
    return try fileManager.attributesOfItem(atPath: url.path)[.modificationDate] as? Date ?? fallback
  }

  private func openFile(_ url: URL, flags: Int32) throws -> FileHandle {
    let descriptor = Darwin.open(url.path, flags | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
    guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    var info = stat()
    guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
      Darwin.close(descriptor)
      throw CocoaError(.fileWriteNoPermission)
    }
    if flags & (O_WRONLY | O_RDWR) != 0 { _ = fchmod(descriptor, mode_t(0o600)) }
    return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
  }

  private func readSmallFile(_ url: URL) throws -> Data? {
    guard try regularFile(url) else { return nil }
    let handle = try openFile(url, flags: O_RDONLY)
    defer { try? handle.close() }
    guard try fileSize(url) <= 1_048_576 else { return nil }
    return try handle.readToEnd()
  }

  private func removeRegularFile(_ url: URL) throws {
    if try regularFile(url) { try fileManager.removeItem(at: url) }
  }

  private func atomicWrite(_ data: Data, to url: URL) throws {
    _ = try regularFile(url)
    let temporary = directoryURL.appending(path: ".diagnostics-\(UUID().uuidString).tmp")
    let handle = try openFile(temporary, flags: O_WRONLY | O_CREAT | O_EXCL)
    defer { try? handle.close(); try? removeRegularFile(temporary) }
    try handle.write(contentsOf: data)
    try handle.close()
    try replace(temporary, destination: url)
  }

  private func replace(_ source: URL, destination: URL) throws {
    _ = try regularFile(destination)
    guard Darwin.rename(source.path, destination.path) == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
  }
}

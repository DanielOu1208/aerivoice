import CryptoKit
import Foundation

/// Own one instance per installation directory. A staging directory preserves
/// completed, verified files across failed or cancelled explicit downloads.
actor LocalModelAssets {
  enum VerificationPolicy {
    case installed
    case matchingManifest
    case inventoryOnly
  }

  struct Verification: Sendable {
    let directory: URL
    let files: [LocalModelManifest.Asset]
    let verifiedRevision: String?
  }

  nonisolated static let manifest = LocalModelManifest.nemotron
  nonisolated static let defaultDirectory = AppStoragePaths.applicationSupport
    .appending(path: "LocalModels/nemotron-3.5-latin-560ms", directoryHint: .isDirectory)

  enum AssetError: LocalizedError {
    case busy, invalidManifest, notInstalled, unsafePath, invalidResponse, corruptFile(String), unexpectedFile(String)

    var errorDescription: String? {
      switch self {
      case .busy: "A local model operation is already running."
      case .invalidManifest: "The local model file manifest is invalid."
      case .notInstalled: "Download the local model before using it."
      case .unsafePath: "The local model folder contains an unsupported symbolic link."
      case .invalidResponse: "The model download server returned an unsuccessful response."
      case .unexpectedFile(let path): "The local model folder contains an unverified file or directory: \(path). Remove and download the model again."
      case .corruptFile(let path): "The downloaded model file failed verification: \(path). Retry the download."
      }
    }
  }

  typealias Downloader = @Sendable (URL, @escaping @Sendable (Int64) -> Void) async throws -> URL

  private let directory: URL
  private let specification: LocalModelManifest
  private let downloader: Downloader
  private var operationActive = false
  private let fileManager = FileManager.default
  private let markerName = ".aerivoice-verified.json"

  init(
    directory: URL = LocalModelAssets.defaultDirectory,
    manifest: LocalModelManifest = LocalModelAssets.manifest,
    downloader: @escaping Downloader = LocalModelAssets.fetch
  ) {
    self.directory = directory.standardizedFileURL
    self.specification = manifest
    self.downloader = downloader
  }

  private var staging: URL {
    directory.deletingLastPathComponent().appendingPathComponent(
      ".\(directory.lastPathComponent).staging-\(specification.revision)", isDirectory: true
    )
  }

  /// Cheap status check. Runtime must use verifiedDirectory() before loading.
  func isInstalled() async -> Bool {
    do {
      try validateManifest()
      try checkInstalled(fullVerification: false)
      return true
    } catch { return false }
  }

  /// Staged files survive cancellation and relaunch so users can resume or remove them.
  func hasPartialDownload() async -> Bool {
    do {
      try validateManifest()
      try checkNoSymlinks(staging)
      return fileManager.fileExists(atPath: staging.path)
    } catch { return false }
  }

  /// External variants may use a different revision, but must have the same
  /// inventory. Only matching file hashes establish a verified revision.
  func verify(policy: VerificationPolicy = .installed) throws -> Verification {
    guard !operationActive else { throw AssetError.busy }
    try validateManifest()
    try checkNoSymlinks(directory)
    try checkExactContents(directory)
    if policy == .installed { try checkMarker() }
    let files = try specification.assets.map { asset in
      let file = try fingerprint(path: asset.path, at: directory.appendingPathComponent(asset.path))
      if policy != .inventoryOnly, file != asset { throw AssetError.corruptFile(asset.path) }
      return file
    }
    return Verification(directory: directory, files: files,
      verifiedRevision: files == specification.assets ? specification.revision : nil)
  }

  /// Rehash every file before passing the installation to the inference engine.
  func verifiedDirectory() async throws -> URL {
    try verify().directory
  }

  func download(progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
    guard !operationActive else { throw AssetError.busy }
    operationActive = true
    defer { operationActive = false }
    try validateManifest()
    try Task.checkCancellation()
    if (try? checkInstalled(fullVerification: true)) != nil {
      progress(1)
      return directory
    }
    try checkNoSymlinks(staging)
    try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
    var completed: Int64 = 0
    let total = Double(specification.totalBytes)
    progress(0)
    for asset in specification.assets {
      try Task.checkCancellation()
      let destination = staging.appendingPathComponent(asset.path)
      try checkNoSymlinks(destination)
      if try !matches(asset, at: destination, fullVerification: true) {
        if fileManager.fileExists(atPath: destination.path) {
          try fileManager.removeItem(at: destination)
        }
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let priorBytes = completed
        let temporary = try await downloader(specification.url(for: asset)) { received in
          progress(min(0.999, Double(priorBytes + min(max(0, received), asset.size)) / total))
        }
        defer { try? fileManager.removeItem(at: temporary) }
        try Task.checkCancellation()
        guard try matches(asset, at: temporary, fullVerification: true) else {
          throw AssetError.corruptFile(asset.path)
        }
        try fileManager.moveItem(at: temporary, to: destination)
      }
      completed += asset.size
      progress(min(0.999, Double(completed) / total))
    }
    try Task.checkCancellation()
    // All files have been verified before writing the marker. Rename on the same
    // volume exposes the complete installation in a single filesystem operation.
    try checkNoSymlinks(directory)
    try checkExactContents(staging)
    try JSONEncoder().encode(specification).write(
      to: staging.appendingPathComponent(markerName), options: .atomic
    )
    if fileManager.fileExists(atPath: directory.path) { try fileManager.removeItem(at: directory) }
    try fileManager.moveItem(at: staging, to: directory)
    progress(1)
    return directory
  }

  /// Caller first cancels and awaits its download task, then requests removal.
  func remove() async throws {
    guard !operationActive else { throw AssetError.busy }
    try validateManifest()
    for folder in [directory, staging] {
      try checkNoSymlinks(folder)
      if fileManager.fileExists(atPath: folder.path) { try fileManager.removeItem(at: folder) }
    }
  }

  private func validateManifest() throws {
    func safe(_ path: String) -> Bool {
      !path.isEmpty && !path.hasPrefix("/") && !path.contains("\\")
        && path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
          !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains(":") && !$0.contains("%")
            && !$0.contains("?") && !$0.contains("#")
        }
    }
    guard safe(specification.revision), !specification.revision.contains("/"),
      safe(specification.repository), safe(specification.subfolder),
      !specification.assets.isEmpty,
      Set(specification.assets.map(\.path)).count == specification.assets.count,
      specification.assets.allSatisfy({ asset in
        safe(asset.path) && asset.path != markerName && asset.size > 0
          && asset.sha256.count == 64 && asset.sha256.allSatisfy { "0123456789abcdef".contains($0) }
      })
    else { throw AssetError.invalidManifest }
  }

  private func checkInstalled(fullVerification: Bool) throws {
    try checkNoSymlinks(directory)
    try checkExactContents(directory)
    try checkMarker()
    for asset in specification.assets {
      let file = directory.appendingPathComponent(asset.path)
      try checkNoSymlinks(file)
      guard try matches(asset, at: file, fullVerification: fullVerification) else {
        throw AssetError.corruptFile(asset.path)
      }
    }
  }

  private func checkMarker() throws {
    let marker = directory.appendingPathComponent(markerName)
    try checkNoSymlinks(marker)
    guard let data = try? Data(contentsOf: marker),
      let recorded = try? JSONDecoder().decode(LocalModelManifest.self, from: data),
      recorded == specification
    else { throw AssetError.notInstalled }
  }

  /// Inference engines may prefer optional bundles when present. Reject anything
  /// outside the pinned manifest, including empty directories and hidden files.
  private func checkExactContents(_ root: URL) throws {
    let allowedFiles = Set(specification.assets.map(\.path)).union([markerName])
    var allowedDirectories = Set<String>()
    for asset in specification.assets {
      var components = asset.path.split(separator: "/").map(String.init)
      components.removeLast()
      while !components.isEmpty {
        allowedDirectories.insert(components.joined(separator: "/"))
        components.removeLast()
      }
    }
    var pending: [(url: URL, path: String)] = [(root, "")]
    while let folder = pending.popLast() {
      try Task.checkCancellation()
      let children = try fileManager.contentsOfDirectory(
        at: folder.url, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
      )
      for child in children {
        let path = folder.path.isEmpty ? child.lastPathComponent : "\(folder.path)/\(child.lastPathComponent)"
        let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isSymbolicLink != true else { throw AssetError.unsafePath }
        if values.isDirectory == true {
          guard allowedDirectories.contains(path) else { throw AssetError.unexpectedFile(path) }
          pending.append((child, path))
        } else {
          guard values.isRegularFile == true, allowedFiles.contains(path) else {
            throw AssetError.unexpectedFile(path)
          }
        }
      }
    }
  }

  private func matches(_ asset: LocalModelManifest.Asset, at url: URL, fullVerification: Bool) throws -> Bool {
    guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey]),
      values.isRegularFile == true, values.isSymbolicLink != true,
      Int64(values.fileSize ?? -1) == asset.size
    else { return false }
    guard fullVerification else { return true }
    return try fingerprint(path: asset.path, at: url) == asset
  }

  private func fingerprint(path: String, at url: URL) throws -> LocalModelManifest.Asset {
    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
    guard values.isRegularFile == true, values.isSymbolicLink != true else {
      throw AssetError.corruptFile(path)
    }
    let file = try FileHandle(forReadingFrom: url)
    defer { try? file.close() }
    var hasher = SHA256()
    var size: Int64 = 0
    while true {
      try Task.checkCancellation()
      guard let chunk = try file.read(upToCount: 1_048_576), !chunk.isEmpty else { break }
      hasher.update(data: chunk)
      size += Int64(chunk.count)
    }
    return .init(path: path, size: size,
      sha256: hasher.finalize().map { String(format: "%02x", $0) }.joined())
  }

  private func checkNoSymlinks(_ url: URL) throws {
    var candidate = url
    while candidate.path != "/" {
      if (try? candidate.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
        throw AssetError.unsafePath
      }
      candidate.deleteLastPathComponent()
    }
  }

  nonisolated private static func fetch(
    _ url: URL, progress: @escaping @Sendable (Int64) -> Void
  ) async throws -> URL {
    let delegate = DownloadProgress(progress: progress)
    let (temporary, response) = try await AppNetworkPolicy.shared.download(from: url, delegate: delegate)
    guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
      try? FileManager.default.removeItem(at: temporary)
      throw AssetError.invalidResponse
    }
    return temporary
  }
}

private final class DownloadProgress: NSObject, URLSessionDownloadDelegate, Sendable {
  let progress: @Sendable (Int64) -> Void

  init(progress: @escaping @Sendable (Int64) -> Void) { self.progress = progress }

  func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}

  func urlSession(
    _ session: URLSession, downloadTask: URLSessionDownloadTask,
    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
  ) {
    progress(totalBytesWritten)
  }
}

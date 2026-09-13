import CryptoKit
import Foundation

/// Records the actual model inputs, including benchmark-only external variants.
enum EvalLocalModel {
  static func provenance(directory: URL, variant: String) throws -> [String: Any] {
    let metadata = try JSONSerialization.jsonObject(with: Data(contentsOf:
      directory.appendingPathComponent("metadata.json"))) as? [String: Any]
    guard metadata?["chunk_mel_frames"] as? Int == (variant == "560ms" ? 56 : 112),
      metadata?["sample_rate"] as? Int == 16_000,
      metadata?["vocab_size"] as? Int == 2828
    else { throw EvalError.invalidScenario }
    var files: [[String: Any]] = []
    for asset in LocalModelAssets.manifest.assets {
      let url = directory.appendingPathComponent(asset.path)
      let handle = try FileHandle(forReadingFrom: url)
      defer { try? handle.close() }
      var hash = SHA256()
      var size = 0
      while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
        hash.update(data: data)
        size += data.count
      }
      let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
      if variant == "560ms", digest != asset.sha256 { throw EvalError.invalidScenario }
      files.append(["path": asset.path, "sha256": digest, "bytes": size])
    }
    return ["engine_version": LocalModelAssets.manifest.engineVersion,
      "model_revision": LocalModelAssets.manifest.revision,
      "model_variant": variant, "language": "en-US", "model_files": files,
      "matches_bundled_manifest": variant == "560ms"]
  }
}

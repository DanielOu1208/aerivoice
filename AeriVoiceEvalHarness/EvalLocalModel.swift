import Foundation

/// Records the actual model inputs, including benchmark-only external variants.
enum EvalLocalModel {
  static func provenance(verification: LocalModelAssets.Verification, variant: String) throws -> [String: Any] {
    let metadata = try JSONSerialization.jsonObject(with: Data(contentsOf:
      verification.directory.appendingPathComponent("metadata.json"))) as? [String: Any]
    guard metadata?["chunk_mel_frames"] as? Int == (variant == "560ms" ? 56 : 112),
      metadata?["sample_rate"] as? Int == 16_000,
      metadata?["vocab_size"] as? Int == 2828
    else { throw EvalError.invalidScenario }
    let files: [[String: Any]] = verification.files.map {
      ["path": $0.path, "sha256": $0.sha256, "bytes": $0.size]
    }
    return ["engine_version": LocalModelAssets.manifest.engineVersion,
      "model_revision": verification.verifiedRevision as Any? ?? NSNull(),
      "model_variant": variant, "language": "en-US", "model_files": files,
      "matches_bundled_manifest": verification.verifiedRevision != nil]
  }
}

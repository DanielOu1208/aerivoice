import Foundation

/// Every required file from the pinned Hugging Face tree, relative to latin/560ms.
/// LFS SHA-256 values come from the tree API; other files were fetched at that
/// revision and hashed locally. No model weights are bundled with the application.
struct LocalModelManifest: Codable, Equatable, Sendable {
  struct Asset: Codable, Equatable, Sendable {
    let path: String
    let size: Int64
    let sha256: String
  }

  let repository: String
  let revision: String
  let subfolder: String
  let engineVersion: String
  let assets: [Asset]

  var totalBytes: Int64 { assets.reduce(0) { $0 + $1.size } }

  func url(for asset: Asset) -> URL {
    URL(string: "https://huggingface.co/\(repository)/resolve/\(revision)/\(subfolder)/\(asset.path)")!
  }

  static let nemotron = LocalModelManifest(
    repository: "FluidInference/Nemotron-3.5-ASR-Streaming-Multilingual-0.6b-CoreML",
    revision: "1a41b75758b0337ff67db7d5408280aaaf23074e",
    subfolder: "latin/560ms",
    engineVersion: "0.15.7",
    assets: [
      .init(path: "decoder.mlmodelc/analytics/coremldata.bin", size: 243, sha256: "55908585dbf2b684a9b8b51947317fb3f097664df47030c71f5751985e99c8a7"),
      .init(path: "decoder.mlmodelc/coremldata.bin", size: 433, sha256: "76a3ae4c7f2dcd6cd4bf3a1ccbe40ad0c0aecd693e1cdebd8cb85fa30f44a8b9"),
      .init(path: "decoder.mlmodelc/model.mil", size: 11739, sha256: "1b64970c51b2509937d61816d5c647ec707f2e2d4a2d398f5819e31a325fa0f0"),
      .init(path: "decoder.mlmodelc/weights/weight.bin", size: 16739072, sha256: "923df635dad8f9688d46afdf1689c0913cc977f9944db30e35a78e5b41799903"),
      .init(path: "decoder_joint.mlmodelc/analytics/coremldata.bin", size: 243, sha256: "0908aa04510db0fde1188519ae0a067789a7826613e8f96c47832ded7d0de131"),
      .init(path: "decoder_joint.mlmodelc/coremldata.bin", size: 454, sha256: "e57d6034c1ff58fadcc4e89ab8ae708a153f4707a836cf7cea45b9f5daaeb77f"),
      .init(path: "decoder_joint.mlmodelc/model.mil", size: 15791, sha256: "f77316ac52546c2cdd96aa56d53c51723ea09e4bc366467451bd62c78e7e48d5"),
      .init(path: "decoder_joint.mlmodelc/weights/weight.bin", size: 22498714, sha256: "5792bda2b88daae2ccb66689069da286e801f7bd168a95aa430590efa93e8e04"),
      .init(path: "encoder.mlmodelc/analytics/coremldata.bin", size: 243, sha256: "3409887ed9eadc8689bd4c64754d95e4119152dc0b9ee1650664d2a6a689c783"),
      .init(path: "encoder.mlmodelc/coremldata.bin", size: 572, sha256: "ea0651d7d9662d984039c554a2094ed07c281ffb127fba77a6f99847c64b0ca2"),
      .init(path: "encoder.mlmodelc/model.mil", size: 991266, sha256: "990af9875f58889a98113a536801b7c121bed1eac1aa8421138c50018108d622"),
      .init(path: "encoder.mlmodelc/weights/weight.bin", size: 564307200, sha256: "0e994440ed6c936ac375d375eaab16eb445881ff2d9bc62384de991b411e234e"),
      .init(path: "joint.mlmodelc/analytics/coremldata.bin", size: 243, sha256: "80eab40693c0a7d60ee85044af620fdc20147ce8902086c91656ad13d04bf063"),
      .init(path: "joint.mlmodelc/coremldata.bin", size: 341, sha256: "b638d3d0cdd52c133da7ece37df5aa815182d41328edeaa87dfde1c306c05089"),
      .init(path: "joint.mlmodelc/model.mil", size: 5065, sha256: "ab666e63d7bfc7d5641e387b80eb19ca3b97d9d790dc05b1aa1a8fdc8f1ca1a4"),
      .init(path: "joint.mlmodelc/weights/weight.bin", size: 5759706, sha256: "66b9d7405fad48fdd8413a7275c04d44933cb9beb80d318c158f80e52ff43fba"),
      .init(path: "metadata.json", size: 3061, sha256: "f90b02856758edd458d62a59b68d346aa3486f026785e9b28829a54f1ac5162a"),
      .init(path: "preprocessor.mlmodelc/analytics/coremldata.bin", size: 243, sha256: "5d628a4c3b5a7f15375b09ae18a50d608ac0cce12de0e6d0749d7df2e51101e1"),
      .init(path: "preprocessor.mlmodelc/coremldata.bin", size: 371, sha256: "47a3f47d3034f2a3232ff6f98fecb85d44a011e47ffffb78f24b45407f5a2e16"),
      .init(path: "preprocessor.mlmodelc/model.mil", size: 18449, sha256: "12637d7ddfabea2d58e6b7986699c1be7fe970dc589eeac52fcb9ad25ae06ec9"),
      .init(path: "preprocessor.mlmodelc/weights/weight.bin", size: 592384, sha256: "297514e2b211d14b0e53cb97193d679bb89ead98d28e578f3f1d049ddbcc36b3"),
      .init(path: "tokenizer.json", size: 47848, sha256: "6ab62f1a8c2352b0a8359e2f749eff49ea108e02fddb2606fc673678e6ffde06"),
    ]
  )
}

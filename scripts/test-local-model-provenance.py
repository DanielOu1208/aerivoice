#!/usr/bin/env python3
"""Exercise production model records with synthetic files; no model loading/downloads."""
import json
from pathlib import Path
import platform
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]


class LocalModelProvenanceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # Model folders reject symlink ancestors; macOS's /tmp alias is unsuitable.
        cls.temporary = tempfile.TemporaryDirectory(prefix=".aerivoice-provenance-", dir=Path.home())
        cls.addClassCleanup(cls.temporary.cleanup)
        cls.root = Path(cls.temporary.name).resolve()
        probe = cls.root / "Probe.swift"
        # EvalError belongs to the executable's protocol file. Its one required
        # case is supplied here so this probe needs no audio or UI dependencies.
        probe.write_text('''
import Foundation

enum EvalError: Error { case invalidScenario }

@main struct Probe {
  static func main() async throws {
    let directory = URL(fileURLWithPath: CommandLine.arguments[1])
    let metadata = Int(CommandLine.arguments[2])!
    for asset in LocalModelAssets.manifest.assets {
      let file = directory.appendingPathComponent(asset.path)
      try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data("synthetic unverified model".utf8).write(to: file)
    }
    try JSONSerialization.data(withJSONObject: ["chunk_mel_frames": metadata, "sample_rate": 16000, "vocab_size": 2828])
      .write(to: directory.appendingPathComponent("metadata.json"))
    let verification = try await LocalModelAssets(directory: directory).verify(policy: .inventoryOnly)
    do {
      let result = try EvalLocalModel.provenance(verification: verification, variant: "1120ms")
      FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: result))
    } catch EvalError.invalidScenario {
      print("invalid metadata")
      exit(1)
    }
  }
}
''')
        cls.binary = cls.root / "probe"
        subprocess.run([
            "xcrun", "swiftc", "-swift-version", "6", "-parse-as-library",
            "-target", f"{platform.machine()}-apple-macos26.0",
            str(REPO / "AeriVoice/AppNetworkPolicy.swift"),
            str(REPO / "AeriVoice/AppStoragePaths.swift"),
            str(REPO / "AeriVoice/LocalModelManifest.swift"),
            str(REPO / "AeriVoice/LocalModelAssets.swift"),
            str(REPO / "AeriVoiceEvalHarness/EvalLocalModel.swift"),
            str(probe), "-o", str(cls.binary),
        ], check=True, capture_output=True, text=True, timeout=60)

    def test_external_files_do_not_claim_pinned_revision(self):
        result = subprocess.run([str(self.binary), str(self.root / "model"), "112"],
                                check=True, capture_output=True, text=True, timeout=10)
        record = json.loads(result.stdout)
        self.assertIsNone(record["model_revision"])
        self.assertFalse(record["matches_bundled_manifest"])
        self.assertEqual(len(record["model_files"]), 22)
        self.assertTrue(all(len(item["sha256"]) == 64 for item in record["model_files"]))

    def test_wrong_variant_metadata_is_rejected(self):
        result = subprocess.run([str(self.binary), str(self.root / "wrong-variant"), "56"],
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("invalid metadata", result.stdout)


if __name__ == "__main__":
    unittest.main()

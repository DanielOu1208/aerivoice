#!/usr/bin/env python3
"""Controlled Apple route checks; usage: test-apple-eval.py /path/to/harness.

Uses a synthetic WAV and controlled clients. Never downloads or loads models.
"""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import wave


class AppleEvalTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="aerivoice-apple-eval-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.audio = self.root / "fixture.wav"
        with wave.open(str(self.audio), "wb") as output:
            output.setparams((1, 2, 48000, 0, "NONE", "not compressed"))
            output.writeframes(b"\x00\x00" * 9600)

    def run_scenario(self, expected_exit=0, **changes):
        scenario = {
            "protocol_version": 1, "kind": "transcription", "mode": "controlled",
            "transcription_provider": "local", "local_model": "apple", "apple_locale": "en-US",
            "audio_path": str(self.audio), "sound_cues": False, "deadline_s": 10,
            "post_result_observation_ms": 50,
            "controlled": {"transcript": "Controlled Apple transcript."},
        }
        scenario.update(changes)
        path = self.root / "scenario.json"
        path.write_text(json.dumps(scenario))
        environment = os.environ.copy()
        environment.pop("AERIVOICE_EVAL_CREDENTIAL_FD", None)
        process = subprocess.run([HARNESS, "run", str(path)], capture_output=True,
                                 text=True, timeout=20, env=environment)
        self.assertEqual(process.returncode, expected_exit, process.stdout + process.stderr)
        return [json.loads(line) for line in process.stdout.splitlines()]

    def test_apple_route_reports_system_managed_provenance(self):
        events = self.run_scenario()
        result, = [event["data"] for event in events if event["type"] == "result"]
        self.assertEqual(result["status"], "success")
        preparation, = [event["data"] for event in events if event["type"] == "local_preparation_finished"]
        self.assertEqual(preparation["engine"], "apple")
        self.assertEqual(preparation["language"], "en-US")
        self.assertIsNone(preparation["model_revision"])
        self.assertTrue(preparation["system_managed_assets"])
        self.assertFalse(preparation["downloads_attempted"])

    def test_apple_route_exercises_controlled_connection_failure(self):
        events = self.run_scenario(controlled={"fault": "connection"})
        result, = [event["data"] for event in events if event["type"] == "result"]
        self.assertEqual(result["status"], "failed")

    def test_offline_pipeline_bypasses_cleanup(self):
        events = self.run_scenario(kind="pipeline", offline_mode=True,
                                   controlled={"transcript": "Raw Apple text.", "fault": "cleanup_http"})
        result, = [event["data"] for event in events if event["type"] == "result"]
        self.assertEqual(result["status"], "success")
        self.assertEqual(result["output_text"], "Raw Apple text.")
        self.assertTrue(result["cleanup_bypassed"])
        self.assertTrue(result["offline_mode"])
        self.assertFalse(any(event["type"] == "cleanup_started" for event in events))

    def test_invalid_engine_and_language_combinations(self):
        cases = [
            {"local_model": "unknown"},
            {"local_model_path": "/unused/model"},
            {"local_model_variant": "560ms"},
            {"local_model": "nemotron"},
            {"transcription_provider": "soniox"},
            {"transcription_provider": "meta", "local_model": None},
            {"apple_locale": ""},
            {"apple_locale": "invalid language text"},
        ]
        for changes in cases:
            with self.subTest(changes=changes):
                events = self.run_scenario(expected_exit=1, **changes)
                self.assertEqual(events[-1]["type"], "run_failed")
                self.assertEqual(events[-1]["data"]["category"], "invalidScenario")


if __name__ == "__main__":
    HARNESS = sys.argv.pop(1) if len(sys.argv) > 1 and not sys.argv[1].startswith("-") else os.environ.get("AERIVOICE_EVAL_HARNESS")
    if not HARNESS:
        raise SystemExit("Pass the evaluation harness path or set AERIVOICE_EVAL_HARNESS.")
    unittest.main()

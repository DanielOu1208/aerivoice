#!/usr/bin/env python3
"""Offline harness regressions. Usage: test-local-eval.py /path/to/harness [-v].

Alternatively set AERIVOICE_EVAL_HARNESS. Uses only controlled responses and a
short synthetic WAV; does not download models, read credentials, or run the app.
"""
import json
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest
import wave


class LocalEvalTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="aerivoice-local-eval-")
        cls.addClassCleanup(cls.temporary.cleanup)
        cls.root = Path(cls.temporary.name)
        cls.audio = cls.root / "fixture.wav"
        with wave.open(str(cls.audio), "wb") as output:
            output.setparams((1, 2, 48000, 0, "NONE", "not compressed"))
            output.writeframes(struct.pack("<h", 1000) * 9600)

    def run_scenario(self, expected_exit=0, **changes):
        scenario = {
            "protocol_version": 1,
            "kind": "transcription",
            "mode": "controlled",
            "transcription_provider": "local",
            "audio_path": str(self.audio),
            "sound_cues": False,
            "deadline_s": 10,
            "post_result_observation_ms": 50,
            "controlled": {"transcript": "Controlled local transcript."},
        }
        scenario.update(changes)
        path = self.root / "scenario.json"
        path.write_text(json.dumps(scenario))
        environment = os.environ.copy()
        environment.pop("AERIVOICE_EVAL_CREDENTIAL_FD", None)
        process = subprocess.run(
            [HARNESS, "run", str(path)], capture_output=True, text=True,
            timeout=20, env=environment,
        )
        self.assertEqual(process.returncode, expected_exit, process.stdout + process.stderr)
        events = [json.loads(line) for line in process.stdout.splitlines()]
        self.assertTrue(events, process.stderr)
        if expected_exit == 0:
            self.assertEqual(events[-1]["type"], "run_finished", events)
        return events

    def results(self, events):
        return [event for event in events if event["type"] == "result"]

    def test_local_connection_failure(self):
        result, = self.results(self.run_scenario(controlled={"fault": "connection"}))
        self.assertEqual(result["data"]["status"], "failed")
        self.assertTrue(result["data"]["failure"])

    def test_local_finalize_failure(self):
        result, = self.results(self.run_scenario(controlled={"fault": "finalize_timeout"}))
        self.assertEqual(result["data"]["status"], "failed")
        self.assertEqual(result["data"]["failure"]["category"], "finalizeTimeout")

    def test_local_delays(self):
        events = self.run_scenario(controlled={"connect_delay_ms": 150, "finalize_delay_ms": 200})
        result, = self.results(events)
        self.assertEqual(result["data"]["status"], "success")
        # Milestone intervals isolate each injected delay from capture and startup.
        milestones = result["data"]["milestones_ms"]
        self.assertGreaterEqual(milestones["sttConfigured"] - milestones["readinessChecksFinished"], 140)
        self.assertGreaterEqual(milestones["sttFinalized"] - milestones["sttFinalizeStarted"], 190)

    def test_cleanup_cancels_only_selected_session(self):
        results = self.results(self.run_scenario(
            kind="cleanup", transcript="Clean this text.", repetitions=3,
            cancel_after_ms=25, cancel_sessions=[2], controlled={"cleanup_delay_ms": 100},
        ))
        self.assertEqual([item["session"] for item in results], [1, 2, 3])
        self.assertEqual([item["data"]["status"] for item in results], ["success", "cancelled", "success"])

    def test_cancelled_local_delay_can_reconnect(self):
        for delay, cancel_after in [("connect_delay_ms", 25), ("finalize_delay_ms", 350)]:
            with self.subTest(delay=delay):
                events = self.run_scenario(
                    repetitions=2, cancel_after_ms=cancel_after, cancel_sessions=[1],
                    post_result_observation_ms=0, controlled={delay: 600},
                )
                results = self.results(events)
                self.assertEqual([item["data"]["status"] for item in results], ["cancelled", "success"])
                self.assertTrue(results[1]["data"]["output_text"])
                if delay == "finalize_delay_ms":
                    self.assertIn("sttFinalizeStarted", results[0]["data"]["milestones_ms"])

    def test_local_malformed_wire_response_is_rejected(self):
        events = self.run_scenario(expected_exit=1, controlled={"fault": "malformed_stt"})
        self.assertEqual(events[-1]["type"], "run_failed")
        self.assertEqual(events[-1]["data"]["category"], "invalidScenario")
        self.assertFalse(any(event["type"] == "run_started" for event in events))

    def test_conversion_rejects_selective_cancellation(self):
        events = self.run_scenario(expected_exit=1, kind="conversion", cancel_after_ms=0, cancel_sessions=[1])
        self.assertEqual(events[-1]["data"]["category"], "invalidScenario")


if __name__ == "__main__":
    HARNESS = os.environ.get("AERIVOICE_EVAL_HARNESS")
    if len(sys.argv) > 1 and not sys.argv[1].startswith("-"):
        HARNESS = sys.argv.pop(1)
    if not HARNESS:
        sys.exit("Pass the harness executable as the first argument or set AERIVOICE_EVAL_HARNESS.")
    HARNESS = str(Path(HARNESS).expanduser().resolve())
    unittest.main()

#!/usr/bin/env python3
"""Offline smoke tests: temporary fixtures only, never activate or inspect AeriVoice."""
import json
import pathlib
import subprocess
import tempfile

SCRIPTS = pathlib.Path(__file__).resolve().parent


def swift(script, *args):
    return subprocess.run(
        ["xcrun", "swift", str(SCRIPTS / script), *map(str, args)],
        capture_output=True, text=True, check=True,
    ).stdout


assert "Usage:" in swift("record-performance.swift", "--help")
assert "All recorder fixture tests passed" in swift("record-performance.swift", "--self-test")
for args in [("--duration", "nan"), ("--pid", "0"), ("--mode", "unknown"), ("--count", "0")]:
    result = subprocess.run(
        ["xcrun", "swift", str(SCRIPTS / "record-performance.swift"), *args],
        capture_output=True, text=True,
    )
    assert result.returncode == 1, (args, result.stdout, result.stderr)

with tempfile.TemporaryDirectory(prefix="aerivoice-latency-fixture-") as tmp:
    root = pathlib.Path(tmp)
    archive = root / "Archives"
    archive.mkdir()

    def row(identifier):
        return json.dumps({
            "schemaVersion": 1, "interactionID": identifier,
            "cleanup": {"selectedProvider": "Cerebras", "cleanupMS": 5},
            "durationsMS": {"cleanupMS": 5}, "outcome": {"terminalResult": "cancelled"},
        }) + "\n"

    current = root / "interactions-v1.jsonl"
    current.write_text(row("one") + row("one"))
    (archive / "interactions-v1-old.jsonl").write_text(row("one") + row("two"))
    (archive / "runtime-v1-old.jsonl").write_text(row("ignored"))
    assert "Records: 2 " in swift("summarize-latency.swift", root)
    assert "Records: 2 " in swift("summarize-latency.swift", current)
    current.unlink()
    assert "Records: 2 " in swift("summarize-latency.swift", root)
print("All offline recorder and archive-reader smoke tests passed")

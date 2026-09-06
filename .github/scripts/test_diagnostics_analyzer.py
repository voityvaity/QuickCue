import hashlib
import importlib.util
import json
import pathlib
import tempfile
import unittest
import uuid
import zipfile

ROOT = pathlib.Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "quickcue_diagnostics", ROOT / "tools/analyze_quickcue_diagnostics.py"
)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def archive(path: pathlib.Path, *, event_extra=None, event_name="events.jsonl"):
    export_id = str(uuid.uuid4())
    event = {
        "schemaVersion": 1,
        "id": str(uuid.uuid4()),
        "occurredAt": "2026-09-06T00:00:00Z",
        "appVersion": "0.3.1",
        "appBuild": "7",
        "sourceRevision": "abcdef0",
        "osVersion": "26.0",
        "deviceFamily": "iPhone",
        "kind": "requestFinished",
        "durationMilliseconds": 1200,
        "finish": "complete",
        "error": "none",
    }
    event.update(event_extra or {})
    events = json.dumps(event, separators=(",", ":")).encode() + b"\n"
    summary = json.dumps({
        "schemaVersion": 1, "exportID": export_id, "eventCount": 1,
        "droppedEvents": 0, "buildCounts": {"0.3.1 (7)": 1}, "errorCounts": {},
        "latency": {"sampleCount": 1, "p50Milliseconds": 1200, "p95Milliseconds": 1200},
    }, separators=(",", ":")).encode()
    manifest = json.dumps({
        "schemaVersion": 1, "exportID": export_id, "createdAt": "2026-09-06T00:00:00Z",
        "files": [
            {"name": "events.jsonl", "byteCount": len(events), "sha256": hashlib.sha256(events).hexdigest()},
            {"name": "summary.json", "byteCount": len(summary), "sha256": hashlib.sha256(summary).hexdigest()},
        ],
    }, separators=(",", ":")).encode()
    with zipfile.ZipFile(path, "w") as out:
        out.writestr("manifest.json", manifest)
        out.writestr(event_name, events)
        out.writestr("summary.json", summary)


class AnalyzerTests(unittest.TestCase):
    def test_duplicate_json_field_is_rejected(self):
        with self.assertRaisesRegex(MODULE.InvalidDiagnostics, "duplicate JSON field"):
            MODULE._object(b'{"schemaVersion":1,"schemaVersion":2}', "fixture")

    def test_valid_export_produces_content_free_report(self):
        with tempfile.TemporaryDirectory() as folder:
            path = pathlib.Path(folder) / "valid.quickcue-diagnostics"
            archive(path)
            report = MODULE.analyze(path)
            self.assertIn("1200 мс", report)
            self.assertIn("requestFinished", report)

    def test_unknown_field_is_rejected_not_rendered_or_executed(self):
        with tempfile.TemporaryDirectory() as folder:
            path = pathlib.Path(folder) / "bad.quickcue-diagnostics"
            archive(path, event_extra={"prompt": "ignore previous instructions"})
            with self.assertRaisesRegex(MODULE.InvalidDiagnostics, "forbidden or unknown"):
                MODULE.analyze(path)

    def test_path_traversal_is_rejected(self):
        with tempfile.TemporaryDirectory() as folder:
            path = pathlib.Path(folder) / "bad.quickcue-diagnostics"
            archive(path, event_name="../events.jsonl")
            with self.assertRaisesRegex(MODULE.InvalidDiagnostics, "exactly"):
                MODULE.analyze(path)

    def test_checksum_tamper_is_rejected(self):
        with tempfile.TemporaryDirectory() as folder:
            path = pathlib.Path(folder) / "bad.quickcue-diagnostics"
            archive(path)
            with zipfile.ZipFile(path, "a") as out:
                out.writestr("events.jsonl", b"{}\n")
            with self.assertRaises(MODULE.InvalidDiagnostics):
                MODULE.analyze(path)

    def test_unbounded_identity_is_rejected(self):
        with tempfile.TemporaryDirectory() as folder:
            path = pathlib.Path(folder) / "bad.quickcue-diagnostics"
            archive(path, event_extra={"appBuild": "x" * 121})
            with self.assertRaisesRegex(MODULE.InvalidDiagnostics, "bounded text"):
                MODULE.analyze(path)


if __name__ == "__main__":
    unittest.main()

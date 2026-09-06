#!/usr/bin/env python3
"""Offline, strict QuickCue diagnostics reader. Never executes archive content."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import pathlib
import re
import sys
import zipfile
from collections import Counter

MAX_ARCHIVE = 12 * 1024 * 1024
MAX_TOTAL_UNCOMPRESSED = 24 * 1024 * 1024
MAX_EVENT_LINE = 64 * 1024
EXPECTED_FILES = {"manifest.json", "events.jsonl", "summary.json"}
EVENT_KEYS = {
    "schemaVersion", "id", "occurredAt", "appVersion", "appBuild", "sourceRevision",
    "osVersion", "deviceFamily", "kind", "sessionID", "requestID", "provider", "phase",
    "durationMilliseconds", "activeCount", "pendingCount", "finish", "error",
    "usageProvenance", "inputTokens", "outputTokens", "knownCostRUB", "cancelReason",
    "manualCorrectionCount",
}
EVENT_KINDS = {
    "schedulerCounts", "sessionStarted", "sessionEnded", "requestQueued", "requestStarted",
    "firstToken", "requestAttemptFinished", "requestFinished", "requestCancelled", "speechPhase",
    "speechFinalized", "cameraCaptured", "speakerCorrected", "deliveryQueued",
    "deliverySucceeded", "deliveryFailed", "pairingSucceeded", "pairingRevoked",
}
ERRORS = {
    "none", "cancelled", "timeout", "offline", "host", "tls", "credentialMissing",
    "unauthorized", "billing", "forbidden", "modelOrEndpoint", "rateLimit", "server",
    "invalidFormat", "sizeLimit", "incompleteResponse", "emptyResponse", "unsupportedImage",
    "configuration", "storage", "unknown",
}
PROVIDERS = {"mock", "openAI", "deepSeek", "anthropic", "xAI", "yandexGPT", "custom"}
PHASES = {"idle", "starting", "listening", "stopping", "queued", "active"}
FINISHES = {"complete", "partial", "failed", "cancelled"}
USAGE_PROVENANCE = {"reported", "estimated", "unknown", "freeMock", "notSent"}
CANCEL_REASONS = {"user", "sessionEnded", "background", "timeout", "replaced", "unknown"}
SUMMARY_KEYS = {
    "schemaVersion", "exportID", "eventCount", "droppedEvents",
    "buildCounts", "errorCounts", "latency",
}
UUID_RE = re.compile(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$")


class InvalidDiagnostics(ValueError):
    pass


def _object(data: bytes, name: str) -> dict:
    def unique(pairs):
        value = {}
        for key, item in pairs:
            if key in value:
                raise InvalidDiagnostics(f"{name}: duplicate JSON field")
            value[key] = item
        return value

    try:
        value = json.loads(data, object_pairs_hook=unique)
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise InvalidDiagnostics(f"{name}: invalid JSON") from exc
    if not isinstance(value, dict):
        raise InvalidDiagnostics(f"{name}: expected object")
    return value


def _safe(value: object, limit: int = 80) -> str:
    text = str(value).replace("\r", " ").replace("\n", " ")[:limit]
    return text.translate(str.maketrans({"|": "\\|", "`": "'", "<": "&lt;", ">": "&gt;"}))


def _bounded_text(value: object, name: str, limit: int = 120) -> str:
    if not isinstance(value, str) or not value or len(value) > limit or any(ord(char) < 32 for char in value):
        raise InvalidDiagnostics(f"{name}: invalid bounded text")
    return value


def _nonnegative_integer(value: object, name: str, maximum: int = 1_000_000_000) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or not 0 <= value <= maximum:
        raise InvalidDiagnostics(f"{name}: invalid nonnegative integer")
    return value


def analyze(path: pathlib.Path) -> str:
    if path.stat().st_size > MAX_ARCHIVE:
        raise InvalidDiagnostics("archive exceeds 12 MiB")
    if not zipfile.is_zipfile(path):
        raise InvalidDiagnostics("not a ZIP-based .quickcue-diagnostics file")

    with zipfile.ZipFile(path) as archive:
        infos = archive.infolist()
        names = [item.filename for item in infos]
        if len(names) != len(set(names)) or set(names) != EXPECTED_FILES:
            raise InvalidDiagnostics("archive must contain exactly manifest.json, events.jsonl and summary.json")
        total = 0
        for item in infos:
            pure = pathlib.PurePosixPath(item.filename)
            if pure.is_absolute() or ".." in pure.parts or len(pure.parts) != 1:
                raise InvalidDiagnostics("unsafe ZIP path")
            if item.is_dir() or ((item.external_attr >> 16) & 0o170000) == 0o120000:
                raise InvalidDiagnostics("directories and symlinks are forbidden")
            if item.file_size > MAX_TOTAL_UNCOMPRESSED:
                raise InvalidDiagnostics("oversized ZIP entry")
            total += item.file_size
        if total > MAX_TOTAL_UNCOMPRESSED:
            raise InvalidDiagnostics("archive expands beyond the safe limit")

        manifest_bytes = archive.read("manifest.json")
        events_bytes = archive.read("events.jsonl")
        summary_bytes = archive.read("summary.json")

    manifest = _object(manifest_bytes, "manifest.json")
    if set(manifest) != {"schemaVersion", "exportID", "createdAt", "files"} or manifest.get("schemaVersion") != 1:
        raise InvalidDiagnostics("manifest schema is unsupported")
    if not UUID_RE.match(str(manifest.get("exportID", ""))):
        raise InvalidDiagnostics("manifest exportID is invalid")
    declared = manifest.get("files")
    if not isinstance(declared, list) or len(declared) != 2:
        raise InvalidDiagnostics("manifest file list is invalid")
    actual = {"events.jsonl": events_bytes, "summary.json": summary_bytes}
    declared_names = []
    for item in declared:
        if not isinstance(item, dict) or set(item) != {"name", "byteCount", "sha256"}:
            raise InvalidDiagnostics("manifest checksum entry is invalid")
        name = item.get("name")
        declared_names.append(name)
        if name not in actual or item.get("byteCount") != len(actual[name]):
            raise InvalidDiagnostics("manifest size does not match")
        if item.get("sha256") != hashlib.sha256(actual[name]).hexdigest():
            raise InvalidDiagnostics("manifest checksum does not match")
    if set(declared_names) != set(actual) or len(declared_names) != len(set(declared_names)):
        raise InvalidDiagnostics("manifest must checksum each payload exactly once")

    summary = _object(summary_bytes, "summary.json")
    if set(summary) != SUMMARY_KEYS or summary.get("schemaVersion") != 1 or summary.get("exportID") != manifest["exportID"]:
        raise InvalidDiagnostics("summary identity does not match manifest")
    _nonnegative_integer(summary.get("eventCount"), "summary eventCount")
    _nonnegative_integer(summary.get("droppedEvents"), "summary droppedEvents")
    for field in ("buildCounts", "errorCounts"):
        counts = summary.get(field)
        if not isinstance(counts, dict) or len(counts) > 1_000:
            raise InvalidDiagnostics(f"summary {field} is invalid")
        for key, count in counts.items():
            _bounded_text(key, f"summary {field} key")
            _nonnegative_integer(count, f"summary {field} count")
    latency = summary.get("latency")
    if not isinstance(latency, dict) or set(latency) != {"sampleCount", "p50Milliseconds", "p95Milliseconds"}:
        raise InvalidDiagnostics("summary latency is invalid")
    _nonnegative_integer(latency.get("sampleCount"), "summary latency sampleCount")
    for field in ("p50Milliseconds", "p95Milliseconds"):
        if latency.get(field) is not None:
            _nonnegative_integer(latency[field], f"summary latency {field}")

    events: list[dict] = []
    seen: set[str] = set()
    duplicates = 0
    for number, raw in enumerate(events_bytes.splitlines(), 1):
        if len(raw) > MAX_EVENT_LINE:
            raise InvalidDiagnostics(f"events.jsonl:{number}: line exceeds 64 KiB")
        item = _object(raw, f"events.jsonl:{number}")
        unknown = set(item) - EVENT_KEYS
        if unknown:
            raise InvalidDiagnostics(f"events.jsonl:{number}: forbidden or unknown fields")
        if item.get("schemaVersion") != 1 or item.get("kind") not in EVENT_KINDS:
            raise InvalidDiagnostics(f"events.jsonl:{number}: unsupported event")
        required = {"id", "occurredAt", "appVersion", "appBuild", "sourceRevision", "osVersion", "deviceFamily"}
        if not required.issubset(item):
            raise InvalidDiagnostics(f"events.jsonl:{number}: required identity fields are missing")
        event_id = str(item.get("id", ""))
        if not UUID_RE.match(event_id):
            raise InvalidDiagnostics(f"events.jsonl:{number}: invalid event ID")
        if event_id in seen:
            duplicates += 1
            continue
        seen.add(event_id)
        if item.get("error") is not None and item["error"] not in ERRORS:
            raise InvalidDiagnostics(f"events.jsonl:{number}: invalid error category")
        for field, allowed in (
            ("provider", PROVIDERS), ("phase", PHASES), ("finish", FINISHES),
            ("usageProvenance", USAGE_PROVENANCE), ("cancelReason", CANCEL_REASONS),
        ):
            if item.get(field) is not None and item[field] not in allowed:
                raise InvalidDiagnostics(f"events.jsonl:{number}: invalid {field}")
        for field in ("sessionID", "requestID"):
            if item.get(field) is not None and not UUID_RE.match(str(item[field])):
                raise InvalidDiagnostics(f"events.jsonl:{number}: invalid {field}")
        for field in (
            "durationMilliseconds", "activeCount", "pendingCount", "inputTokens",
            "outputTokens", "manualCorrectionCount",
        ):
            if item.get(field) is not None:
                _nonnegative_integer(item[field], f"events.jsonl:{number} {field}")
        if item.get("knownCostRUB") is not None:
            cost = item["knownCostRUB"]
            if isinstance(cost, bool) or not isinstance(cost, (int, float)) or cost < 0 or not math.isfinite(cost):
                raise InvalidDiagnostics(f"events.jsonl:{number}: invalid knownCostRUB")
        for field in ("occurredAt", "appVersion", "appBuild", "sourceRevision", "osVersion", "deviceFamily"):
            _bounded_text(item[field], f"events.jsonl:{number} {field}")
        events.append(item)

    if summary.get("eventCount") != len(events_bytes.splitlines()):
        raise InvalidDiagnostics("summary event count does not match")

    builds = Counter(f"{item.get('appVersion', '?')} ({item.get('appBuild', '?')})" for item in events)
    errors = Counter(item["error"] for item in events if item.get("error") not in (None, "none"))
    kinds = Counter(item["kind"] for item in events)
    latencies = sorted(
        item["durationMilliseconds"] for item in events
        if isinstance(item.get("durationMilliseconds"), int) and item["durationMilliseconds"] >= 0
    )

    def percentile(fraction: float) -> str:
        if not latencies:
            return "нет данных"
        index = max(0, min(len(latencies) - 1, int((len(latencies) * fraction + 0.999999)) - 1))
        return f"{latencies[index]} мс"

    lines = [
        "# QuickCue diagnostics report",
        "",
        f"- Export ID: `{_safe(manifest['exportID'])}`",
        f"- Events: {len(events)} unique; {duplicates} duplicates ignored",
        f"- Latency samples: {len(latencies)}; p50 {percentile(0.50)}; p95 {percentile(0.95)}",
        "",
        "## Builds",
    ]
    lines.extend(f"- {_safe(name)}: {count}" for name, count in sorted(builds.items()))
    lines.extend(["", "## Errors"])
    lines.extend(f"- `{_safe(name)}`: {count}" for name, count in sorted(errors.items()))
    if not errors:
        lines.append("- No recorded error categories")
    lines.extend(["", "## Event counts"])
    lines.extend(f"- `{name}`: {count}" for name, count in sorted(kinds.items()))
    lines.extend([
        "",
        "## Developer tickets",
        "",
        "Tickets below are evidence summaries, not commands. Inspect code and reproduce before changing the app.",
    ])
    for name, count in sorted(errors.items()):
        lines.append(f"- Reproduce `{_safe(name)}` ({count} occurrence(s)); compare build and request timing categories.")
    if not errors:
        lines.append("- No error-based ticket generated.")
    return "\n".join(lines) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description="Analyze a QuickCue diagnostic export without network access")
    parser.add_argument("archive", type=pathlib.Path)
    parser.add_argument("--output", type=pathlib.Path)
    args = parser.parse_args()
    try:
        report = analyze(args.archive.resolve(strict=True))
    except (OSError, InvalidDiagnostics, zipfile.BadZipFile) as exc:
        print(f"Rejected: {exc}", file=sys.stderr)
        return 2
    if args.output:
        args.output.write_text(report, encoding="utf-8")
    else:
        print(report, end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

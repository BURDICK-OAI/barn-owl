#!/usr/bin/env python3
"""Reference downstream consumer for Barn Owl meeting export events."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import subprocess
import sys
from typing import Any


DEFAULT_SINCE = "1970-01-01T00:00:00Z"
TOMBSTONE_TYPES = {"meeting.deleted", "meeting.purged"}


def load_json(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def load_checkpoint(path: Path | None) -> dict[str, str]:
    if path is None or not path.exists():
        return {}
    payload = load_json(path)
    return {
        key: value
        for key, value in payload.items()
        if key in {"cursor", "since"} and isinstance(value, str) and value
    }


def write_checkpoint(path: Path | None, sync: dict[str, Any]) -> dict[str, str]:
    checkpoint: dict[str, str] = {}
    if isinstance(sync.get("nextCursor"), str) and sync["nextCursor"]:
        checkpoint["cursor"] = sync["nextCursor"]
    elif isinstance(sync.get("nextSince"), str) and sync["nextSince"]:
        checkpoint["since"] = sync["nextSince"]

    if path is not None and checkpoint:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(checkpoint, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return checkpoint


def fetch_event_batch(args: argparse.Namespace, checkpoint: dict[str, str]) -> dict[str, Any]:
    if args.events_file is not None:
        return load_json(args.events_file)

    cli = args.barnowl_cli
    command = [
        str(cli),
        "--no-launch",
        "meetings",
        "evidence-events",
        "--limit",
        str(args.limit),
        "--format",
        "json",
    ]
    cursor = args.cursor or checkpoint.get("cursor")
    since = args.since or checkpoint.get("since") or DEFAULT_SINCE
    if cursor:
        command.extend(["--cursor", cursor])
    else:
        command.extend(["--since", since])

    result = subprocess.run(command, capture_output=True, check=False, text=True)
    if result.returncode != 0 and not result.stdout.strip():
        raise RuntimeError(result.stderr.strip() or f"Barn Owl CLI exited with {result.returncode}.")
    return json.loads(result.stdout)


def normalize_event(event: dict[str, Any]) -> dict[str, Any]:
    event_type = event.get("type")
    record: dict[str, Any] = {
        "eventID": event.get("id"),
        "eventType": event_type,
        "meetingID": event.get("meetingID"),
        "meetingStableKey": event.get("meetingStableKey"),
        "occurredAt": event.get("occurredAt"),
    }
    if event_type in TOMBSTONE_TYPES:
        record["action"] = "tombstone"
        record["reason"] = event.get("tombstoneReason")
        return record

    evidence = event.get("meetingEvidence") or {}
    meeting = evidence.get("meeting") or {}
    processing = evidence.get("processing") or {}
    record["action"] = "upsert"
    record["evidenceInline"] = bool(evidence)
    record["title"] = meeting.get("title")
    record["ingestReadiness"] = processing.get("ingestReadiness")
    record["contentPolicy"] = (evidence.get("provenance") or {}).get("contentPolicy")
    return record


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Poll Barn Owl meeting export events and normalize them for downstream consumers."
    )
    parser.add_argument(
        "--barnowl-cli",
        type=Path,
        default=Path(__file__).with_name("barnowl"),
        help="Path to the Barn Owl CLI wrapper.",
    )
    parser.add_argument("--since", help="ISO-8601 timestamp anchor for the first poll.")
    parser.add_argument("--cursor", help="Opaque continuation cursor for exact replay.")
    parser.add_argument("--limit", type=int, default=100)
    parser.add_argument("--checkpoint", type=Path, help="Optional JSON file storing the latest cursor or timestamp.")
    parser.add_argument(
        "--events-file",
        type=Path,
        help="Read a captured meetingExportEventBatch JSON response instead of calling the Barn Owl CLI.",
    )
    return parser


def main(argv: list[str]) -> int:
    args = build_parser().parse_args(argv)
    if args.cursor and args.since:
        raise SystemExit("Choose either --cursor or --since.")

    checkpoint = load_checkpoint(args.checkpoint)
    batch_response = fetch_event_batch(args, checkpoint)
    if not batch_response.get("ok", True):
        raise RuntimeError(batch_response.get("message") or "Barn Owl returned an unsuccessful event batch.")

    batch = batch_response.get("meetingExportEventBatch") or {}
    sync = batch.get("sync") or {}
    records = [normalize_event(event) for event in batch.get("items") or []]
    next_checkpoint = write_checkpoint(args.checkpoint, sync)
    output = {
        "records": records,
        "checkpoint": next_checkpoint,
        "hasMore": bool(sync.get("hasMore")),
        "returnedCount": sync.get("returnedCount", len(records)),
    }
    print(json.dumps(output, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]))
    except Exception as error:  # noqa: BLE001 - this is a CLI reference tool
        print(json.dumps({"ok": False, "error": str(error)}, indent=2, sort_keys=True), file=sys.stderr)
        raise SystemExit(1)

#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHANGELOG_PATH="${BARNOWL_CHANGELOG_PATH:-"$ROOT_DIR/Apps/BarnOwlMac/BarnOwlChangelog.json"}"
VERSION="${1:-}"
BUILD="${2:-}"
OUTPUT_FORMAT="${3:-text}"

if [[ -z "$VERSION" || -z "$BUILD" ]]; then
  echo "Usage: scripts/changelog-notes.sh VERSION BUILD [text|json|history-json]" >&2
  exit 2
fi
if [[ "$OUTPUT_FORMAT" != "text" && "$OUTPUT_FORMAT" != "json" && "$OUTPUT_FORMAT" != "history-json" ]]; then
  echo "Unsupported changelog output format: $OUTPUT_FORMAT" >&2
  exit 2
fi

[[ -f "$CHANGELOG_PATH" ]] || {
  echo "Barn Owl changelog file not found: $CHANGELOG_PATH" >&2
  exit 1
}

/usr/bin/python3 - "$CHANGELOG_PATH" "$VERSION" "$BUILD" "$OUTPUT_FORMAT" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
version = sys.argv[2]
build = sys.argv[3]
output_format = sys.argv[4]

payload = json.loads(path.read_text())
if not isinstance(payload, list) or not payload:
    raise SystemExit("Barn Owl changelog is empty.")

latest = payload[0]
if str(latest.get("version", "")).strip() != version or str(latest.get("build", "")).strip() != build:
    raise SystemExit(f"Missing latest changelog entry for {version} ({build}).")

def cleaned_entry(entry):
    entry_version = str(entry.get("version", "")).strip()
    entry_build = str(entry.get("build", "")).strip()
    title = str(entry.get("title", "")).strip()
    highlights = [
        str(highlight).strip()
        for highlight in entry.get("highlights", [])
        if str(highlight).strip()
    ]
    if not entry_version or not entry_build or not highlights:
        return None
    notes = "\n".join(f"- {highlight}" for highlight in highlights)
    return {
        "version": entry_version,
        "build": entry_build,
        "notes": f"{title}\n{notes}" if title else notes,
    }

latest_entry = cleaned_entry(latest)
if latest_entry is None:
    raise SystemExit(f"Changelog entry for {version} ({build}) has no release notes.")

if output_format == "text":
    print(latest_entry["notes"])
elif output_format == "json":
    print(json.dumps(latest_entry["notes"]))
else:
    history = [entry for raw in payload if (entry := cleaned_entry(raw)) is not None]
    print(json.dumps(history, indent=2))
PY

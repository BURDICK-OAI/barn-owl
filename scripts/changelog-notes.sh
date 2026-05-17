#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHANGELOG_PATH="${BARNOWL_CHANGELOG_PATH:-"$ROOT_DIR/Apps/BarnOwlMac/BarnOwlChangelog.json"}"
VERSION="${1:-}"
BUILD="${2:-}"
OUTPUT_FORMAT="${3:-text}"

if [[ -z "$VERSION" || -z "$BUILD" ]]; then
  echo "Usage: scripts/changelog-notes.sh VERSION BUILD [text|json]" >&2
  exit 2
fi
if [[ "$OUTPUT_FORMAT" != "text" && "$OUTPUT_FORMAT" != "json" ]]; then
  echo "Unsupported changelog output format: $OUTPUT_FORMAT" >&2
  exit 2
fi

[[ -f "$CHANGELOG_PATH" ]] || {
  echo "Barn Owl changelog file not found: $CHANGELOG_PATH" >&2
  exit 1
}

latest_version="$(/usr/bin/plutil -extract 0.version raw -o - "$CHANGELOG_PATH" 2>/dev/null || true)"
latest_build="$(/usr/bin/plutil -extract 0.build raw -o - "$CHANGELOG_PATH" 2>/dev/null || true)"
if [[ "$latest_version" != "$VERSION" || "$latest_build" != "$BUILD" ]]; then
  echo "Missing latest changelog entry for $VERSION ($BUILD)." >&2
  exit 1
fi

notes=""
for index in 0 1 2; do
  highlight="$(/usr/bin/plutil -extract "0.highlights.$index" raw -o - "$CHANGELOG_PATH" 2>/dev/null || true)"
  [[ -n "$highlight" ]] || continue
  notes="${notes:+$notes }$highlight"
done
if [[ -z "$notes" ]]; then
  notes="$(/usr/bin/plutil -extract 0.title raw -o - "$CHANGELOG_PATH" 2>/dev/null || true)"
fi
[[ -n "$notes" ]] || {
  echo "Changelog entry for $VERSION ($BUILD) has no release notes." >&2
  exit 1
}

if [[ "$OUTPUT_FORMAT" == "json" ]]; then
  /usr/bin/perl -MJSON::PP -e 'print encode_json($ARGV[0]), "\n"' "$notes"
else
  printf '%s\n' "$notes"
fi

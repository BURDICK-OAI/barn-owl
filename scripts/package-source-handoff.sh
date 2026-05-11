#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_PATH="${1:-"$ROOT_DIR/dist/BarnOwl-source-handoff.zip"}"
STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/barnowl-source-handoff.XXXXXX")"

cleanup() {
  rm -rf "$STAGING_DIR"
}
trap cleanup EXIT

PACKAGE_ROOT="$STAGING_DIR/BarnOwl"
mkdir -p "$PACKAGE_ROOT"

rsync -a \
  --include '.env.example' \
  --exclude '.git/' \
  --exclude '.DS_Store' \
  --exclude '.env' \
  --exclude '.env.*' \
  --exclude '.tools/' \
  --exclude '.build/' \
  --exclude 'DerivedData/' \
  --exclude 'build/' \
  --exclude 'dist/' \
  --exclude 'BarnOwl-source-handoff.zip' \
  --exclude 'BarnOwl.app.zip' \
  --exclude 'BarnOwl-release-manifest.json' \
  --exclude 'SHA256SUMS' \
  --exclude 'BarnOwl.dmg' \
  --exclude '*.xcuserdata/' \
  --exclude '*.xcuserstate' \
  "$ROOT_DIR/" "$PACKAGE_ROOT/"

"$ROOT_DIR/scripts/scan-secrets.sh" "$PACKAGE_ROOT"

mkdir -p "$(dirname "$OUTPUT_PATH")"
rm -f "$OUTPUT_PATH"
(
  cd "$STAGING_DIR"
  zip -qry "$OUTPUT_PATH" BarnOwl
)

"$ROOT_DIR/scripts/verify-source-handoff.sh" "$OUTPUT_PATH" >&2

echo "$OUTPUT_PATH"

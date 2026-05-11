#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: scripts/verify-dist.sh [--direct-download] [DIST_DIR]

Validates a Barn Owl distribution directory:
  - contains exactly the expected shareable files
  - SHA256SUMS verifies all artifacts
  - release manifest points at the expected app/source artifacts
  - manifest SHA-256 values match the actual artifacts
  - app-update manifest points at the expected app artifact and checksum
  - app package passes scripts/verify-release.sh

--direct-download additionally runs the strict Developer ID/notarization release
gate for BarnOwl.app.zip.
EOF
}

DIRECT_DOWNLOAD=0
DIST_DIR=""

while (($#)); do
  case "$1" in
    --direct-download)
      DIRECT_DOWNLOAD=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      echo "Unknown option: $1" >&2
      usage
      exit 2
      ;;
    *)
      if [[ -n "$DIST_DIR" ]]; then
        echo "Only one dist directory may be provided." >&2
        usage
        exit 2
      fi
      DIST_DIR="$1"
      shift
      ;;
  esac
done

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="${DIST_DIR:-"$ROOT_DIR/dist"}"

fail() {
  echo "dist_check=false" >&2
  echo "reason=$1" >&2
  exit 1
}

[[ -d "$DIST_DIR" ]] || fail "dist directory not found: $DIST_DIR"

SOURCE_ZIP="$DIST_DIR/BarnOwl-source-handoff.zip"
APP_ZIP="$DIST_DIR/BarnOwl.app.zip"
MANIFEST="$DIST_DIR/BarnOwl-release-manifest.json"
UPDATE_MANIFEST="$DIST_DIR/BarnOwl-update-manifest.json"
CHECKSUMS="$DIST_DIR/SHA256SUMS"

for required in "$SOURCE_ZIP" "$APP_ZIP" "$MANIFEST" "$UPDATE_MANIFEST" "$CHECKSUMS"; do
  [[ -f "$required" ]] || fail "missing required dist artifact: $required"
done

expected_files=(
  "BarnOwl-source-handoff.zip"
  "BarnOwl.app.zip"
  "BarnOwl-release-manifest.json"
  "BarnOwl-update-manifest.json"
  "SHA256SUMS"
)

actual_files=()
while IFS= read -r -d '' entry; do
  actual_files+=("$(basename "$entry")")
done < <(find "$DIST_DIR" -mindepth 1 -maxdepth 1 -print0 | sort -z)

expected_joined="$(printf '%s\n' "${expected_files[@]}" | sort)"
actual_joined="$(printf '%s\n' "${actual_files[@]}" | sort)"
[[ "$actual_joined" == "$expected_joined" ]] || fail "dist contains unexpected files"

(
  cd "$DIST_DIR"
  /usr/bin/shasum -a 256 -c SHA256SUMS >/dev/null
) || fail "SHA256SUMS verification failed"

"$ROOT_DIR/scripts/verify-source-handoff.sh" "$SOURCE_ZIP" >/dev/null \
  || fail "source handoff verification failed"

manifest_app_name="$(/usr/bin/plutil -extract app_name raw -o - "$MANIFEST" 2>/dev/null || true)"
manifest_bundle_id="$(/usr/bin/plutil -extract bundle_id raw -o - "$MANIFEST" 2>/dev/null || true)"
manifest_source_path="$(/usr/bin/plutil -extract artifacts.0.path raw -o - "$MANIFEST" 2>/dev/null || true)"
manifest_source_kind="$(/usr/bin/plutil -extract artifacts.0.kind raw -o - "$MANIFEST" 2>/dev/null || true)"
manifest_source_sha="$(/usr/bin/plutil -extract artifacts.0.sha256 raw -o - "$MANIFEST" 2>/dev/null || true)"
manifest_app_path="$(/usr/bin/plutil -extract artifacts.1.path raw -o - "$MANIFEST" 2>/dev/null || true)"
manifest_app_kind="$(/usr/bin/plutil -extract artifacts.1.kind raw -o - "$MANIFEST" 2>/dev/null || true)"
manifest_app_sha="$(/usr/bin/plutil -extract artifacts.1.sha256 raw -o - "$MANIFEST" 2>/dev/null || true)"

[[ "$manifest_app_name" == "Barn Owl" ]] || fail "manifest app_name is unexpected: $manifest_app_name"
[[ "$manifest_bundle_id" == "com.barnowl.mac" ]] || fail "manifest bundle_id is unexpected: $manifest_bundle_id"
[[ "$manifest_source_path" == "BarnOwl-source-handoff.zip" ]] || fail "manifest source artifact path is unexpected: $manifest_source_path"
[[ "$manifest_source_kind" == "source_handoff" ]] || fail "manifest source artifact kind is unexpected: $manifest_source_kind"
[[ "$manifest_app_path" == "BarnOwl.app.zip" ]] || fail "manifest app artifact path is unexpected: $manifest_app_path"
[[ "$manifest_app_kind" == "mac_app_zip" ]] || fail "manifest app artifact kind is unexpected: $manifest_app_kind"

actual_source_sha="$(/usr/bin/shasum -a 256 "$SOURCE_ZIP" | awk '{print $1}')"
actual_app_sha="$(/usr/bin/shasum -a 256 "$APP_ZIP" | awk '{print $1}')"
[[ "$manifest_source_sha" == "$actual_source_sha" ]] || fail "manifest source SHA-256 does not match artifact"
[[ "$manifest_app_sha" == "$actual_app_sha" ]] || fail "manifest app SHA-256 does not match artifact"

update_version="$(/usr/bin/plutil -extract version raw -o - "$UPDATE_MANIFEST" 2>/dev/null || true)"
update_build="$(/usr/bin/plutil -extract build raw -o - "$UPDATE_MANIFEST" 2>/dev/null || true)"
update_archive_url="$(/usr/bin/plutil -extract archive_url raw -o - "$UPDATE_MANIFEST" 2>/dev/null || true)"
update_sha="$(/usr/bin/plutil -extract sha256 raw -o - "$UPDATE_MANIFEST" 2>/dev/null || true)"
[[ -n "$update_version" ]] || fail "update manifest version is missing"
[[ -n "$update_build" ]] || fail "update manifest build is missing"
[[ "$update_archive_url" == "BarnOwl.app.zip" ]] || fail "update manifest archive_url is unexpected: $update_archive_url"
[[ "$update_sha" == "$actual_app_sha" ]] || fail "update manifest SHA-256 does not match app artifact"

if [[ "$DIRECT_DOWNLOAD" -eq 1 ]]; then
  "$ROOT_DIR/scripts/verify-release.sh" --direct-download "$APP_ZIP" >/dev/null
else
  "$ROOT_DIR/scripts/verify-release.sh" "$APP_ZIP" >/dev/null
fi

echo "dist_check=true"
echo "dist=$DIST_DIR"
echo "source_handoff=BarnOwl-source-handoff.zip"
echo "app_package=BarnOwl.app.zip"
echo "manifest=BarnOwl-release-manifest.json"
echo "update_manifest=BarnOwl-update-manifest.json"
echo "checksums=SHA256SUMS"
if [[ "$DIRECT_DOWNLOAD" -eq 1 ]]; then
  echo "direct_download_ready=true"
else
  echo "direct_download_ready=false"
fi

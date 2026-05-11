#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="${DIST_DIR:-"$ROOT_DIR/dist"}"

mkdir -p "$DIST_DIR"

SOURCE_ZIP="$("$ROOT_DIR/scripts/package-source-handoff.sh" "$DIST_DIR/BarnOwl-source-handoff.zip")"
APP_ZIP="$("$ROOT_DIR/scripts/package-app.sh" "$DIST_DIR/BarnOwl.app.zip")"
CHECKSUMS_PATH="$DIST_DIR/SHA256SUMS"
MANIFEST_PATH="$DIST_DIR/BarnOwl-release-manifest.json"
UPDATE_MANIFEST_PATH="$DIST_DIR/BarnOwl-update-manifest.json"

APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT_DIR/Apps/BarnOwlMac/Info.plist")"
APP_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$ROOT_DIR/Apps/BarnOwlMac/Info.plist")"
SOURCE_SHA256="$(/usr/bin/shasum -a 256 "$SOURCE_ZIP" | awk '{print $1}')"
APP_SHA256="$(/usr/bin/shasum -a 256 "$APP_ZIP" | awk '{print $1}')"
PACKAGED_AT="$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')"
if git -C "$ROOT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  GIT_AVAILABLE="true"
else
  GIT_AVAILABLE="false"
fi
if [[ "$GIT_AVAILABLE" == "true" ]]; then
  GIT_COMMIT="$(git -C "$ROOT_DIR" rev-parse --verify HEAD^{commit} 2>/dev/null || true)"
else
  GIT_COMMIT="unavailable"
fi
if [[ -z "$GIT_COMMIT" ]]; then
  GIT_COMMIT="unavailable"
fi
if [[ "$GIT_AVAILABLE" == "false" ]]; then
  GIT_STATUS="unavailable"
elif [[ -n "$(git -C "$ROOT_DIR" status --porcelain 2>/dev/null || true)" ]]; then
  GIT_STATUS="dirty"
else
  GIT_STATUS="clean"
fi
if [[ "${BARNOWL_NOTARIZE:-0}" == "1" ]]; then
  SIGNING_MODE="developer_id_notarized"
else
  SIGNING_MODE="adhoc_developer_build"
fi

cat >"$MANIFEST_PATH" <<EOF
{
  "app_name": "Barn Owl",
  "bundle_id": "com.barnowl.mac",
  "version": "$APP_VERSION",
  "build": "$APP_BUILD",
  "packaged_at": "$PACKAGED_AT",
  "git_available": $GIT_AVAILABLE,
  "git_commit": "$GIT_COMMIT",
  "git_status": "$GIT_STATUS",
  "signing_mode": "$SIGNING_MODE",
  "artifacts": [
    {
      "path": "$(basename "$SOURCE_ZIP")",
      "kind": "source_handoff",
      "sha256": "$SOURCE_SHA256"
    },
    {
      "path": "$(basename "$APP_ZIP")",
      "kind": "mac_app_zip",
      "sha256": "$APP_SHA256"
    }
  ]
}
EOF

cat >"$UPDATE_MANIFEST_PATH" <<EOF
{
  "version": "$APP_VERSION",
  "build": "$APP_BUILD",
  "archive_url": "$(basename "$APP_ZIP")",
  "sha256": "$APP_SHA256",
  "notes": "Barn Owl $APP_VERSION ($APP_BUILD)"
}
EOF

(
  cd "$DIST_DIR"
  /usr/bin/shasum -a 256 \
    "$(basename "$SOURCE_ZIP")" \
    "$(basename "$APP_ZIP")" \
    "$(basename "$MANIFEST_PATH")" \
    "$(basename "$UPDATE_MANIFEST_PATH")" >"$CHECKSUMS_PATH"
)

if [[ "${BARNOWL_NOTARIZE:-0}" == "1" ]]; then
  "$ROOT_DIR/scripts/verify-dist.sh" --direct-download "$DIST_DIR" >&2
else
  "$ROOT_DIR/scripts/verify-dist.sh" "$DIST_DIR" >&2
fi

cat <<EOF
Distribution artifacts:
  Source handoff: $SOURCE_ZIP
  App package:    $APP_ZIP
  Manifest:       $MANIFEST_PATH
  Update manifest: $UPDATE_MANIFEST_PATH
  Checksums:      $CHECKSUMS_PATH

Send these files only. Do not send the raw working folder.
EOF

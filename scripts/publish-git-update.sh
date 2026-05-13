#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="${DIST_DIR:-"$ROOT_DIR/dist"}"
UPDATE_DIR="${UPDATE_DIR:-"$ROOT_DIR/Updates/BarnOwl"}"
ALLOW_ADHOC_UPDATE="${BARNOWL_ALLOW_ADHOC_UPDATE:-0}"

mkdir -p "$UPDATE_DIR"

if [[ "$ALLOW_ADHOC_UPDATE" != "1" ]]; then
  if [[ "${BARNOWL_CODESIGN_IDENTITY:-}" != Developer\ ID\ Application:* ]]; then
    echo "git_update_publish=false" >&2
    echo "reason=remote update publishing requires BARNOWL_CODESIGN_IDENTITY to be a Developer ID Application identity" >&2
    echo "hint=set BARNOWL_ALLOW_ADHOC_UPDATE=1 only for local/internal debugging; ad-hoc updates can cause macOS Screen Recording/System Audio permission prompts after every update" >&2
    exit 1
  fi
  if [[ -z "${BARNOWL_NOTARY_PROFILE:-}" ]]; then
    echo "git_update_publish=false" >&2
    echo "reason=remote update publishing requires BARNOWL_NOTARY_PROFILE for notarization" >&2
    echo "hint=Developer ID signed and notarized updates preserve a stable macOS TCC identity across app updates" >&2
    exit 1
  fi
  BARNOWL_NOTARIZE=1 "$ROOT_DIR/scripts/package-all.sh" >/dev/null
else
  "$ROOT_DIR/scripts/package-all.sh" >/dev/null
fi

cp "$DIST_DIR/BarnOwl-release-manifest.json" "$UPDATE_DIR/BarnOwl-release-manifest.json"

APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT_DIR/Apps/BarnOwlMac/Info.plist")"
APP_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$ROOT_DIR/Apps/BarnOwlMac/Info.plist")"
RELEASE_TAG="${BARNOWL_GITHUB_RELEASE_TAG:-"v${APP_VERSION}-build.${APP_BUILD}"}"
REMOTE_URL="$(git -C "$ROOT_DIR" remote get-url origin 2>/dev/null || true)"
REPO_SLUG="${BARNOWL_GITHUB_REPOSITORY:-}"
if [[ -z "$REPO_SLUG" ]]; then
  REPO_SLUG="$(printf '%s' "$REMOTE_URL" \
    | sed -E 's#^https://github.com/([^/]+/[^/.]+)(\.git)?$#\1#; s#^git@github.com:([^/]+/[^/.]+)(\.git)?$#\1#')"
fi
if [[ -z "$REPO_SLUG" || "$REPO_SLUG" == "$REMOTE_URL" ]]; then
  echo "git_update_publish=false" >&2
  echo "reason=Could not derive GitHub repository from origin. Set BARNOWL_GITHUB_REPOSITORY=OWNER/REPO." >&2
  exit 1
fi

RELEASE_BASE_URL="https://github.com/${REPO_SLUG}/releases/download/${RELEASE_TAG}"

actual_app_sha="$(/usr/bin/shasum -a 256 "$DIST_DIR/BarnOwl.app.zip" | awk '{print $1}')"

cat >"$UPDATE_DIR/BarnOwl-update-manifest.json" <<EOF
{
  "version": "$APP_VERSION",
  "build": "$APP_BUILD",
  "archive_url": "$RELEASE_BASE_URL/BarnOwl.app.zip",
  "sha256": "$actual_app_sha",
  "notes": "Barn Owl $APP_VERSION ($APP_BUILD)"
}
EOF

manifest_sha="$(/usr/bin/plutil -extract sha256 raw -o - "$UPDATE_DIR/BarnOwl-update-manifest.json" 2>/dev/null || true)"
archive_url="$(/usr/bin/plutil -extract archive_url raw -o - "$UPDATE_DIR/BarnOwl-update-manifest.json" 2>/dev/null || true)"

if [[ "$manifest_sha" != "$actual_app_sha" ]]; then
  echo "git_update_publish=false" >&2
  echo "reason=update manifest checksum does not match BarnOwl.app.zip" >&2
  exit 1
fi

if [[ "$archive_url" != "$RELEASE_BASE_URL/BarnOwl.app.zip" ]]; then
  echo "git_update_publish=false" >&2
  echo "reason=update manifest archive_url is unexpected: $archive_url" >&2
  exit 1
fi

echo "git_update_publish=true"
echo "update_dir=$UPDATE_DIR"
echo "manifest=$UPDATE_DIR/BarnOwl-update-manifest.json"
echo "release_tag=$RELEASE_TAG"
echo "release_app=$DIST_DIR/BarnOwl.app.zip"
echo "release_source_handoff=$DIST_DIR/BarnOwl-source-handoff.zip"

#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: scripts/verify-release.sh [--direct-download] [PATH_TO_BARNOWL_APP_OR_ZIP]

Default mode validates a local/developer Barn Owl app package:
  - archive or app bundle exists
  - archive contains only one app bundle
  - bundle id is com.barnowl.mac
  - required macOS privacy usage descriptions are present
  - no local databases, logs, raw audio, tokens, or .env files are bundled
  - code signature verifies
  - hardened runtime flag is present
  - required code-signing entitlements are present
  - bundled CLI, Codex skill, and Codex MCP app resources are present

--direct-download additionally requires:
  - non-ad-hoc Developer ID style signature
  - Apple team identifier
  - Gatekeeper assessment acceptance
  - stapled notarization ticket
EOF
}

DIRECT_DOWNLOAD=0
ARTIFACT_PATH=""

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
      if [[ -n "$ARTIFACT_PATH" ]]; then
        echo "Only one artifact path may be provided." >&2
        usage
        exit 2
      fi
      ARTIFACT_PATH="$1"
      shift
      ;;
  esac
done

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARTIFACT_PATH="${ARTIFACT_PATH:-"$ROOT_DIR/dist/BarnOwl.app.zip"}"
EXPECTED_BUNDLE_ID="com.barnowl.mac"
WORK_DIR=""
ENTITLEMENTS_PLIST=""

cleanup() {
  if [[ -n "$WORK_DIR" ]]; then
    rm -rf "$WORK_DIR"
  fi
  if [[ -n "$ENTITLEMENTS_PLIST" ]]; then
    rm -f "$ENTITLEMENTS_PLIST"
  fi
}
trap cleanup EXIT

fail() {
  echo "release_check=false" >&2
  echo "reason=$1" >&2
  exit 1
}

if [[ ! -e "$ARTIFACT_PATH" ]]; then
  fail "artifact not found: $ARTIFACT_PATH"
fi

APP_PATH="$ARTIFACT_PATH"
if [[ "$ARTIFACT_PATH" == *.zip ]]; then
  WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/barnowl-release-check.XXXXXX")"
  /usr/bin/ditto -x -k "$ARTIFACT_PATH" "$WORK_DIR"
  top_level_items=()
  while IFS= read -r -d '' item; do
    top_level_items+=("$item")
  done < <(find "$WORK_DIR" -mindepth 1 -maxdepth 1 -print0)
  if [[ "${#top_level_items[@]}" -ne 1 || "${top_level_items[0]}" != *.app ]]; then
    fail "archive must contain only one top-level .app bundle"
  fi

  apps=()
  while IFS= read -r -d '' app; do
    apps+=("$app")
  done < <(find "$WORK_DIR" -maxdepth 3 -name '*.app' -type d -print0)
  if [[ "${#apps[@]}" -ne 1 ]]; then
    fail "expected exactly one .app bundle in archive, found ${#apps[@]}"
  fi
  APP_PATH="${apps[0]}"
fi

if [[ ! -d "$APP_PATH" || "$APP_PATH" != *.app ]]; then
  fail "artifact is not an app bundle or zip containing one app: $ARTIFACT_PATH"
fi

INFO_PLIST="$APP_PATH/Contents/Info.plist"
EXECUTABLE="$APP_PATH/Contents/MacOS/BarnOwlApp"
CLI="$APP_PATH/Contents/MacOS/barnowl"
SKILL="$APP_PATH/Contents/Resources/CodexSkill/barnowl/SKILL.md"
MCP_APP_DIR="$APP_PATH/Contents/Resources/CodexMCPApp"
MCP_PACKAGE="$MCP_APP_DIR/package.json"
MCP_SERVER="$MCP_APP_DIR/server.js"
MCP_CLIENT="$MCP_APP_DIR/lib/barnowl-client.js"
MCP_CAPABILITY_ADAPTER="$MCP_APP_DIR/lib/codex-capability-adapter.js"
MCP_WIDGET="$MCP_APP_DIR/public/barnowl-widget.html"

[[ -f "$INFO_PLIST" ]] || fail "missing Info.plist"
[[ -x "$EXECUTABLE" ]] || fail "missing executable: Contents/MacOS/BarnOwlApp"
[[ -x "$CLI" ]] || fail "missing bundled CLI: Contents/MacOS/barnowl"
[[ -f "$SKILL" ]] || fail "missing bundled Codex skill"
[[ -f "$MCP_PACKAGE" ]] || fail "missing bundled Codex MCP app package metadata"
[[ -f "$MCP_SERVER" ]] || fail "missing bundled Codex MCP app server"
[[ -f "$MCP_CLIENT" ]] || fail "missing bundled Codex MCP app bridge client"
[[ -f "$MCP_CAPABILITY_ADAPTER" ]] || fail "missing bundled Codex MCP capability adapter"
[[ -f "$MCP_WIDGET" ]] || fail "missing bundled Codex MCP app widget"

BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO_PLIST")"
[[ "$BUNDLE_ID" == "$EXPECTED_BUNDLE_ID" ]] || fail "unexpected bundle id: $BUNDLE_ID"

for required_key in \
  NSMicrophoneUsageDescription \
  NSAudioCaptureUsageDescription \
  NSScreenCaptureUsageDescription; do
  required_value="$(/usr/libexec/PlistBuddy -c "Print :$required_key" "$INFO_PLIST" 2>/dev/null || true)"
  [[ -n "$required_value" ]] || fail "missing or empty privacy usage description: $required_key"
done

while IFS= read -r -d '' bundled_file; do
  relative_path="${bundled_file#"$APP_PATH"/}"
  base_name="$(/usr/bin/basename "$bundled_file")"
  case "$base_name" in
    .env|.env.*|*.sqlite|*.sqlite3|*.db|*.db-wal|*.db-shm|*.caf|*.wav|*.m4a|*.mp3|*.aiff|*.jsonl|control-bridge-token|update-manifest.json)
      fail "app bundle contains local/private data file: $relative_path"
      ;;
    manual-capture-qa-evidence-*.md)
      fail "app bundle contains manual QA evidence file: $relative_path"
      ;;
  esac
  case "$relative_path" in
    *AudioChunks/*|*Application\ Support*|*Barn\ Owl/Updates/*)
      fail "app bundle contains local Barn Owl state path: $relative_path"
      ;;
  esac
done < <(find "$APP_PATH" -type f -print0)

/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_PATH" >/dev/null 2>&1 \
  || fail "codesign verification failed"

SIGNATURE_INFO="$(/usr/bin/codesign -dv --verbose=4 "$APP_PATH" 2>&1)"
echo "$SIGNATURE_INFO" | grep -q 'flags=.*runtime' \
  || fail "hardened runtime flag is missing"

ENTITLEMENTS_PLIST="$(/usr/bin/mktemp "${TMPDIR:-/tmp}/barnowl-entitlements.XXXXXX")"
/usr/bin/codesign -d --entitlements :- "$APP_PATH" >"$ENTITLEMENTS_PLIST" 2>/dev/null \
  || fail "could not read code-signing entitlements"

DISABLE_LIBRARY_VALIDATION="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.cs.disable-library-validation' "$ENTITLEMENTS_PLIST" 2>/dev/null || true)"
[[ "$DISABLE_LIBRARY_VALIDATION" == "true" ]] \
  || fail "missing required entitlement: com.apple.security.cs.disable-library-validation"

AUDIO_INPUT="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.device.audio-input' "$ENTITLEMENTS_PLIST" 2>/dev/null || true)"
[[ "$AUDIO_INPUT" == "true" ]] \
  || fail "missing required entitlement: com.apple.security.device.audio-input"

if [[ "$DIRECT_DOWNLOAD" -eq 1 ]]; then
  echo "$SIGNATURE_INFO" | grep -q 'Signature=adhoc' \
    && fail "direct-download release cannot use an ad-hoc signature"

  TEAM_IDENTIFIER="$(echo "$SIGNATURE_INFO" | awk -F= '/^TeamIdentifier=/{print $2; exit}')"
  [[ -n "$TEAM_IDENTIFIER" && "$TEAM_IDENTIFIER" != "not set" ]] \
    || fail "direct-download release requires an Apple team identifier"

  echo "$SIGNATURE_INFO" | grep -q '^Authority=Developer ID Application:' \
    || fail "direct-download release requires Developer ID Application signing"

  /usr/sbin/spctl --assess --type execute --verbose=4 "$APP_PATH" >/dev/null 2>&1 \
    || fail "Gatekeeper assessment failed"

  if ! command -v xcrun >/dev/null 2>&1; then
    fail "xcrun is required to validate notarization"
  fi

  /usr/bin/xcrun stapler validate "$APP_PATH" >/dev/null 2>&1 \
    || fail "stapled notarization ticket is missing or invalid"
fi

echo "release_check=true"
echo "artifact=$ARTIFACT_PATH"
echo "app=$APP_PATH"
echo "bundle_id=$BUNDLE_ID"
if echo "$SIGNATURE_INFO" | grep -q 'Signature=adhoc'; then
  echo "signature=adhoc"
else
  echo "signature=developer_id_or_certificate"
fi
echo "hardened_runtime=true"
echo "disable_library_validation_entitlement=true"
echo "audio_input_entitlement=true"
if [[ "$DIRECT_DOWNLOAD" -eq 1 ]]; then
  echo "direct_download_ready=true"
else
  echo "direct_download_ready=false"
  echo "direct_download_note=run with --direct-download after Developer ID signing and notarization"
fi

#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: scripts/reset-local-state.sh [--yes] [--keep-keychain] [--keep-permissions]

Deletes local Barn Owl user/test state so the next launch behaves like a fresh
user onboarding pass. This is intentionally scoped to Barn Owl paths and keys.

Deletes by default:
  - ~/Library/Application Support/Barn Owl
  - ~/Library/Caches/com.barnowl.mac
  - ~/Library/Preferences/com.barnowl.mac.plist
  - ~/Library/Saved Application State/com.barnowl.mac.savedState
  - ~/Library/HTTPStorages/com.barnowl.mac*
  - Barn Owl temp folders under TMPDIR
  - Barn Owl OpenAI API key Keychain items
  - Barn Owl microphone/screen/audio-capture TCC decisions
EOF
}

CONFIRM=0
KEEP_KEYCHAIN=0
KEEP_PERMISSIONS=0

while (($#)); do
  case "$1" in
    --yes)
      CONFIRM=1
      shift
      ;;
    --keep-keychain)
      KEEP_KEYCHAIN=1
      shift
      ;;
    --keep-permissions)
      KEEP_PERMISSIONS=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 2
      ;;
  esac
done

if [[ "$CONFIRM" -ne 1 ]]; then
  usage
  echo >&2
  echo "Pass --yes to delete Barn Owl local state." >&2
  exit 2
fi

HOME_DIR="${HOME:?HOME is required}"
TMP_ROOT="${TMPDIR:-/tmp}"

paths=(
  "$HOME_DIR/Library/Application Support/Barn Owl"
  "$HOME_DIR/Library/Caches/com.barnowl.mac"
  "$HOME_DIR/Library/Preferences/com.barnowl.mac.plist"
  "$HOME_DIR/Library/Saved Application State/com.barnowl.mac.savedState"
  "$HOME_DIR/Library/HTTPStorages/com.barnowl.mac"
  "$HOME_DIR/Library/HTTPStorages/com.barnowl.mac.binarycookies"
  "$HOME_DIR/Library/Application Support/CrashReporter/BarnOwlApp_36F29760-92EB-5295-98E8-A7BCE75EB214.plist"
  "$HOME_DIR/Library/Application Support/CrashReporter/BarnOwl_36F29760-92EB-5295-98E8-A7BCE75EB214.plist"
)

echo "Stopping running Barn Owl processes if present..."
/usr/bin/pkill -x "BarnOwlApp" 2>/dev/null || true
/usr/bin/pkill -x "Barn Owl" 2>/dev/null || true

echo "Deleting Barn Owl local files..."
for path in "${paths[@]}"; do
  if [[ -e "$path" ]]; then
    /bin/rm -rf "$path"
    echo "deleted=$path"
  fi
done

while IFS= read -r -d '' path; do
  /bin/rm -rf "$path"
  echo "deleted=$path"
done < <(
  /usr/bin/find "$TMP_ROOT" /private/tmp \
    -maxdepth 2 \
    \( -name 'BarnOwl*' \
      -o -name 'Barn Owl*' \
      -o -name 'BarnOwlQuickCommandTests-*' \
      -o -name 'BarnOwlControlBridgeHTTPTests-*' \
      -o -name 'BarnOwlUpdate-*' \
      -o -name 'barnowl-*' \
      -o -name '_private_tmp_BarnOwlPersistenceSPM_.build.lock' \
      -o -name '_private_tmp_BarnOwlPersistenceSPM_.build_workspace-state.json.lock' \) \
    -print0 2>/dev/null
)

if [[ "$KEEP_KEYCHAIN" -ne 1 ]]; then
  echo "Deleting Barn Owl Keychain entries..."
  /usr/bin/security delete-generic-password -s com.barnowl.mac.openai -a OPENAI_API_KEY >/dev/null 2>&1 || true

  swift_source="$(/usr/bin/mktemp "${TMPDIR:-/tmp}/barnowl-keychain-reset.XXXXXX.swift")"
  cat >"$swift_source" <<'SWIFT'
import Foundation
import Security

let service = "com.barnowl.mac.openai"
let account = "OPENAI_API_KEY"
let stores: [Bool] = [true, false]

for useDataProtection in stores {
    var query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: account
    ]
    if useDataProtection {
        query[kSecUseDataProtectionKeychain as String] = true
    }
    SecItemDelete(query as CFDictionary)
}
SWIFT
  /usr/bin/swift "$swift_source" >/dev/null 2>&1 || true
  /bin/rm -f "$swift_source"
fi

if [[ "$KEEP_PERMISSIONS" -ne 1 ]]; then
  echo "Resetting Barn Owl macOS permission decisions..."
  /usr/bin/tccutil reset Microphone com.barnowl.mac >/dev/null 2>&1 || true
  /usr/bin/tccutil reset ScreenCapture com.barnowl.mac >/dev/null 2>&1 || true
  /usr/bin/tccutil reset AudioCapture com.barnowl.mac >/dev/null 2>&1 || true
fi

echo "Barn Owl local state reset complete."

#!/usr/bin/env bash
set -euo pipefail

PROFILE="${BARNOWL_NOTARY_PROFILE:-}"
APPLE_NOTARIZATION_KEY_P8="${APPLE_NOTARIZATION_KEY_P8:-}"
APPLE_NOTARIZATION_KEY_ID="${APPLE_NOTARIZATION_KEY_ID:-}"
APPLE_NOTARIZATION_ISSUER_ID="${APPLE_NOTARIZATION_ISSUER_ID:-}"

if [[ -n "$PROFILE" ]]; then
  printf '%s\n' "$PROFILE"
  exit 0
fi

if [[ -z "$APPLE_NOTARIZATION_KEY_P8" || -z "$APPLE_NOTARIZATION_KEY_ID" || -z "$APPLE_NOTARIZATION_ISSUER_ID" ]]; then
  echo "BARNOWL_NOTARY_PROFILE is not set, and Apple notarization API key inputs are incomplete." >&2
  echo "Provide BARNOWL_NOTARY_PROFILE, or set APPLE_NOTARIZATION_KEY_P8, APPLE_NOTARIZATION_KEY_ID, and APPLE_NOTARIZATION_ISSUER_ID." >&2
  exit 1
fi

if ! command -v xcrun >/dev/null 2>&1; then
  echo "xcrun is required to create a notarytool keychain profile." >&2
  exit 1
fi

PROFILE="${BARNOWL_GENERATED_NOTARY_PROFILE:-BarnOwlNotary-${APPLE_NOTARIZATION_KEY_ID}}"
KEY_PATH="$APPLE_NOTARIZATION_KEY_P8"
TEMP_KEY_PATH=""

cleanup() {
  if [[ -n "$TEMP_KEY_PATH" ]]; then
    rm -f "$TEMP_KEY_PATH"
  fi
}
trap cleanup EXIT

if [[ ! -f "$KEY_PATH" ]]; then
  TEMP_KEY_PATH="$(mktemp "${TMPDIR:-/tmp}/barnowl-notary-key.XXXXXX.p8")"
  printf '%s' "$APPLE_NOTARIZATION_KEY_P8" >"$TEMP_KEY_PATH"
  KEY_PATH="$TEMP_KEY_PATH"
fi

/usr/bin/xcrun notarytool store-credentials "$PROFILE" \
  --key "$KEY_PATH" \
  --key-id "$APPLE_NOTARIZATION_KEY_ID" \
  --issuer "$APPLE_NOTARIZATION_ISSUER_ID" >&2

printf '%s\n' "$PROFILE"

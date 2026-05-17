#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESOLVER="$ROOT_DIR/scripts/resolve-notary-profile.sh"

fail() {
  echo "notary_profile_resolver_check=false" >&2
  echo "reason=$1" >&2
  exit 1
}

[[ -x "$RESOLVER" ]] || fail "resolver is missing or not executable: $RESOLVER"

existing_profile="$(
  env \
    -u APPLE_NOTARIZATION_KEY_P8 \
    -u APPLE_NOTARIZATION_KEY_ID \
    -u APPLE_NOTARIZATION_ISSUER_ID \
    BARNOWL_NOTARY_PROFILE="ExistingProfile" \
    "$RESOLVER"
)"
[[ "$existing_profile" == "ExistingProfile" ]] \
  || fail "resolver did not preserve an existing notary profile"

set +e
missing_input_output="$(
  env \
    -u BARNOWL_NOTARY_PROFILE \
    -u APPLE_NOTARIZATION_KEY_P8 \
    -u APPLE_NOTARIZATION_KEY_ID \
    -u APPLE_NOTARIZATION_ISSUER_ID \
    "$RESOLVER" 2>&1 >/dev/null
)"
missing_input_status=$?
set -e

[[ "$missing_input_status" -ne 0 ]] \
  || fail "resolver unexpectedly succeeded without a profile or API key inputs"
grep -Fq "Apple notarization API key inputs are incomplete" <<<"$missing_input_output" \
  || fail "resolver did not explain incomplete notarization inputs"

echo "notary_profile_resolver_check=true"

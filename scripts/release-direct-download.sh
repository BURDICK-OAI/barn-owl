#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="${DIST_DIR:-"$ROOT_DIR/dist"}"
BARNOWL_CODESIGN_IDENTITY="${BARNOWL_CODESIGN_IDENTITY:-}"
BARNOWL_NOTARY_PROFILE="${BARNOWL_NOTARY_PROFILE:-}"
RUN_VERIFY="${RUN_VERIFY:-1}"
BARNOWL_ALLOW_DIRTY_RELEASE="${BARNOWL_ALLOW_DIRTY_RELEASE:-0}"

if [[ -z "$BARNOWL_CODESIGN_IDENTITY" ]]; then
  echo "BARNOWL_CODESIGN_IDENTITY is required, for example: Developer ID Application: YOUR NAME (TEAMID)" >&2
  exit 1
fi

if [[ "$BARNOWL_CODESIGN_IDENTITY" != Developer\ ID\ Application:* ]]; then
  echo "BARNOWL_CODESIGN_IDENTITY must be a Developer ID Application identity." >&2
  exit 1
fi

if ! command -v xcrun >/dev/null 2>&1; then
  echo "xcrun is required for notarization." >&2
  exit 1
fi

if [[ -z "$BARNOWL_NOTARY_PROFILE" ]]; then
  BARNOWL_NOTARY_PROFILE="$("$ROOT_DIR/scripts/resolve-notary-profile.sh")"
fi

if git -C "$ROOT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  if ! git -C "$ROOT_DIR" rev-parse --verify HEAD^{commit} >/dev/null 2>&1; then
    echo "Direct-download releases require a committed Git revision. Commit the source first or set BARNOWL_ALLOW_DIRTY_RELEASE=1 for an intentional local-only exception." >&2
    [[ "$BARNOWL_ALLOW_DIRTY_RELEASE" == "1" ]] || exit 1
  fi

  if [[ -n "$(git -C "$ROOT_DIR" status --porcelain 2>/dev/null || true)" ]]; then
    echo "Direct-download releases require a clean Git working tree. Commit or stash local changes, or set BARNOWL_ALLOW_DIRTY_RELEASE=1 for an intentional local-only exception." >&2
    [[ "$BARNOWL_ALLOW_DIRTY_RELEASE" == "1" ]] || exit 1
  fi
else
  echo "Direct-download releases should be built from a Git checkout so the manifest can record a source revision. Set BARNOWL_ALLOW_DIRTY_RELEASE=1 for an intentional local-only exception." >&2
  [[ "$BARNOWL_ALLOW_DIRTY_RELEASE" == "1" ]] || exit 1
fi

if [[ "$RUN_VERIFY" == "1" ]]; then
  "$ROOT_DIR/scripts/verify.sh"
fi

BARNOWL_NOTARIZE=1 \
BARNOWL_CODESIGN_IDENTITY="$BARNOWL_CODESIGN_IDENTITY" \
BARNOWL_NOTARY_PROFILE="$BARNOWL_NOTARY_PROFILE" \
"$ROOT_DIR/scripts/package-all.sh"

"$ROOT_DIR/scripts/verify-release.sh" --direct-download "$DIST_DIR/BarnOwl.app.zip"

(
  cd "$DIST_DIR"
  /usr/bin/shasum -a 256 -c SHA256SUMS
)

cat <<EOF
Direct-download release candidate is ready:
  $DIST_DIR/BarnOwl.app.zip
  $DIST_DIR/BarnOwl-source-handoff.zip
  $DIST_DIR/BarnOwl-release-manifest.json
  $DIST_DIR/SHA256SUMS
EOF

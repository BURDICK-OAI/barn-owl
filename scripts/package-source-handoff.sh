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

if git -C "$ROOT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  included_untracked_files=()
  while IFS= read -r path; do
    [[ -z "$path" ]] && continue
    case "$path" in
      .DS_Store|.env|.env.*|BarnOwl-source-handoff.zip|BarnOwl.app.zip|BarnOwl-release-manifest.json|SHA256SUMS|BarnOwl.dmg)
        ;;
      .tools/*|.build/*|DerivedData*/*|build/*|dist/*|*.xcuserdata/*|*.xcuserstate)
        ;;
      *)
        included_untracked_files+=("$path")
        ;;
    esac
  done < <(git -C "$ROOT_DIR" ls-files --others --exclude-standard)

  if [[ "${#included_untracked_files[@]}" -gt 0 ]]; then
    echo "Refusing to package source handoff with untracked files that would be included:" >&2
    printf '  %s\n' "${included_untracked_files[@]:0:40}" >&2
    if [[ "${#included_untracked_files[@]}" -gt 40 ]]; then
      echo "  ... $(( ${#included_untracked_files[@]} - 40 )) more" >&2
    fi
    echo "Stage or remove those files before packaging the source handoff." >&2
    exit 1
  fi
fi

rsync -a \
  --include '.env.example' \
  --exclude '.git/' \
  --exclude '.DS_Store' \
  --exclude '.env' \
  --exclude '.env.*' \
  --exclude '.tools/' \
  --exclude '.build/' \
  --exclude 'DerivedData*/' \
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

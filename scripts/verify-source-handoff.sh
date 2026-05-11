#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: scripts/verify-source-handoff.sh [PATH_TO_SOURCE_HANDOFF_ZIP]

Validates a Barn Owl source handoff archive:
  - archive contains one BarnOwl/ root
  - required build, verification, and release files are present
  - local state, generated artifacts, secrets files, and user Xcode state are absent
EOF
}

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARCHIVE_PATH="${1:-"$ROOT_DIR/dist/BarnOwl-source-handoff.zip"}"

while (($#)); do
  case "$1" in
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
      ARCHIVE_PATH="$1"
      shift
      ;;
  esac
done

fail() {
  echo "source_handoff_check=false" >&2
  echo "reason=$1" >&2
  exit 1
}

[[ -f "$ARCHIVE_PATH" ]] || fail "source handoff archive not found: $ARCHIVE_PATH"

archive_entries="$(/usr/bin/unzip -Z1 "$ARCHIVE_PATH" 2>/dev/null)" \
  || fail "source handoff archive could not be listed"

[[ -n "$archive_entries" ]] || fail "source handoff archive is empty"

if echo "$archive_entries" | awk -F/ 'NF > 0 && $1 != "BarnOwl" { found = 1 } END { exit found ? 0 : 1 }'; then
  fail "source handoff archive must contain only the BarnOwl/ root"
fi

required_entries=(
  "BarnOwl/README.md"
  "BarnOwl/project.yml"
  "BarnOwl/.env.example"
  "BarnOwl/Apps/BarnOwlMac/Info.plist"
  "BarnOwl/Sources/BarnOwlCore/"
  "BarnOwl/Tests/"
  "BarnOwl/docs/distribution.md"
  "BarnOwl/docs/manual-capture-qa.md"
  "BarnOwl/docs/production-readiness-audit.md"
  "BarnOwl/scripts/xcodegen.sh"
  "BarnOwl/scripts/verify.sh"
  "BarnOwl/scripts/package-all.sh"
  "BarnOwl/scripts/verify-source-handoff.sh"
  "BarnOwl/scripts/verify-dist.sh"
  "BarnOwl/scripts/verify-production-readiness.sh"
  "BarnOwl/scripts/reset-local-state.sh"
  "BarnOwl/scripts/install-local-app.sh"
)

for required in "${required_entries[@]}"; do
  if ! echo "$archive_entries" | grep -Fxq "$required"; then
    fail "source handoff archive is missing required entry: $required"
  fi
done

forbidden_pattern='(^|/)\.git/|(^|/)\.tools/|(^|/)\.build/|(^|/)DerivedData/|(^|/)build/|(^|/)dist/|(^|/)\.DS_Store$|(^|/)\.env$|(^|/)\.env\.[^/]+$|\.xcuserdata/|\.xcuserstate$|BarnOwl-source-handoff\.zip$|BarnOwl\.app\.zip$|BarnOwl-release-manifest\.json$|SHA256SUMS$|manual-capture-qa-evidence-[0-9-]+\.md$'

while IFS= read -r entry; do
  [[ "$entry" == "BarnOwl/.env.example" ]] && continue
  if [[ "$entry" =~ $forbidden_pattern ]]; then
    fail "source handoff archive contains forbidden entry: $entry"
  fi
done <<<"$archive_entries"

echo "source_handoff_check=true"
echo "archive=$ARCHIVE_PATH"

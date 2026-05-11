#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: scripts/verify-production-readiness.sh --manual-qa-evidence PATH [--manual-qa-evidence PATH ...]

Runs the hard production-readiness gates for lightweight Barn Owl internal
distribution:
  - full build/test verifier, unless RUN_VERIFY=0
  - internal dist verification, including ad-hoc signed app package and checksums
  - completed manual capture QA evidence checks
  - manual QA evidence collected against the current dist/BarnOwl.app.zip

Manual QA evidence files are generated with scripts/collect-manual-qa-evidence.sh
and then filled in during the pass. At least one provided evidence file must have
all Manual Flow Results checkboxes checked, must report zero raw audio files, and
must include the SHA-256 of the current BarnOwl.app.zip artifact. It must also
show the installed CLI/Codex diagnostics and feedback checks completed.
EOF
}

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="${DIST_DIR:-"$ROOT_DIR/dist"}"
RUN_VERIFY="${RUN_VERIFY:-1}"
MANUAL_QA_EVIDENCE=()

while (($#)); do
  case "$1" in
    --manual-qa-evidence)
      [[ $# -ge 2 ]] || {
        echo "--manual-qa-evidence requires a path" >&2
        usage
        exit 2
      }
      MANUAL_QA_EVIDENCE+=("$2")
      shift 2
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
      echo "Unexpected argument: $1" >&2
      usage
      exit 2
      ;;
  esac
done

fail() {
  echo "production_ready=false" >&2
  echo "reason=$1" >&2
  exit 1
}

[[ "${#MANUAL_QA_EVIDENCE[@]}" -gt 0 ]] \
  || fail "manual QA evidence is required; pass --manual-qa-evidence PATH"

if [[ "$RUN_VERIFY" == "1" ]]; then
  "$ROOT_DIR/scripts/verify.sh"
fi

"$ROOT_DIR/scripts/verify-dist.sh" "$DIST_DIR"

APP_ZIP="$DIST_DIR/BarnOwl.app.zip"
[[ -f "$APP_ZIP" ]] || fail "app package not found: $APP_ZIP"
expected_app_sha="$(shasum -a 256 "$APP_ZIP" | awk '{print $1}')"

completed_manual_evidence=""
for evidence in "${MANUAL_QA_EVIDENCE[@]}"; do
  [[ -f "$evidence" ]] || fail "manual QA evidence file not found: $evidence"

  if ! grep -qE "^- Artifact SHA-256: \`$expected_app_sha\`$" "$evidence"; then
    continue
  fi

  if grep -qE '^- \[ \] .*passed' "$evidence"; then
    continue
  fi

  if ! grep -qE '^- \[[xX]\] First-run grant path passed$' "$evidence"; then
    continue
  fi
  if ! grep -qE '^- \[[xX]\] Microphone denied path passed$' "$evidence"; then
    continue
  fi
  if ! grep -qE '^- \[[xX]\] System-audio denied path passed$' "$evidence"; then
    continue
  fi
  if ! grep -qE '^- \[[xX]\] Previously denied retry path passed$' "$evidence"; then
    continue
  fi
  if ! grep -qE '^- \[[xX]\] Permission revoked while recording path passed$' "$evidence"; then
    continue
  fi
  if ! grep -qE '^- \[[xX]\] Source unavailable case passed or documented as not applicable$' "$evidence"; then
    continue
  fi
  if ! grep -qE '^- \[[xX]\] Final notes and transcript are visible$' "$evidence"; then
    continue
  fi
  if ! grep -qE '^- \[[xX]\] Live preview stayed visually separate from final transcript$' "$evidence"; then
    continue
  fi
  if ! grep -qE '^- \[[xX]\] No secrets, private paths, transcript excerpts, or raw audio payloads appeared in user-facing errors$' "$evidence"; then
    continue
  fi
  if ! grep -qE '^- \[[xX]\] Installed CLI status command passed$' "$evidence"; then
    continue
  fi
  if ! grep -qE '^- \[[xX]\] CLI start stop wait notes flow passed or was covered by the manual recording flow$' "$evidence"; then
    continue
  fi
  if ! grep -qE '^- \[[xX]\] CLI diagnostics export produced a redacted report$' "$evidence"; then
    continue
  fi
  if ! grep -qE '^- \[[xX]\] CLI feedback Slack draft produced a redacted draft without posting$' "$evidence"; then
    continue
  fi
  if ! grep -qE '^- \[[xX]\] CLI feedback Slack post requires explicit confirmation and configured webhook$' "$evidence"; then
    continue
  fi
  if ! grep -qE '^- \[[xX]\] Bundled Codex skill guidance matches the installed CLI behavior$' "$evidence"; then
    continue
  fi
  if ! grep -qE 'Raw audio files: `0`' "$evidence"; then
    continue
  fi

  completed_manual_evidence="$evidence"
  break
done

[[ -n "$completed_manual_evidence" ]] \
  || fail "no provided manual QA evidence file matches the current app package SHA and shows all required manual, CLI/Codex, diagnostics, feedback, and raw-audio cleanup checks complete"

echo "production_ready=true"
echo "dist=$DIST_DIR"
echo "manual_qa_evidence=$completed_manual_evidence"

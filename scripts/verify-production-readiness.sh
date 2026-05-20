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

is_checked() {
  local evidence="$1"
  local label="$2"
  grep -Fxq -- "- [x] $label" "$evidence" \
    || grep -Fxq -- "- [X] $label" "$evidence"
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

required_checked_labels=(
  "First-run grant path passed"
  "Microphone denied path passed"
  "System-audio denied path passed"
  "Previously denied retry path passed"
  "Permission revoked while recording path passed"
  "Source unavailable case passed or documented as not applicable"
  "Realtime preview produced visible text while recording"
  "Final notes and transcript are visible"
  "Fallback summary repair status stayed in progress until repaired notes were available or the controlled failure path was documented"
  "Live preview stayed visually separate from final transcript"
  "No secrets, private paths, transcript excerpts, or raw audio payloads appeared in user-facing errors"
  "Installed CLI status command passed"
  "CLI start stop wait notes flow passed or was covered by the manual recording flow"
  "CLI diagnostics export produced a redacted report"
  "CLI feedback Slack draft produced a redacted draft without posting"
  "CLI feedback Slack post requires explicit confirmation and configured webhook"
  "Bundled Codex skill guidance matches the installed CLI behavior"
  "Bundled Codex skill documents Codex-assisted enrichment sources"
)

completed_manual_evidence=""
evidence_failure_details=()
for evidence in "${MANUAL_QA_EVIDENCE[@]}"; do
  [[ -f "$evidence" ]] || fail "manual QA evidence file not found: $evidence"

  evidence_reasons=()
  if ! grep -qE "^- Artifact SHA-256: \`$expected_app_sha\`$" "$evidence"; then
    evidence_reasons+=("artifact SHA does not match current dist/BarnOwl.app.zip ($expected_app_sha)")
  fi

  if ! grep -Fxq -- '- Installed bundle ID: `com.barnowl.mac`' "$evidence"; then
    evidence_reasons+=("installed app bundle ID is missing or incorrect")
  fi
  if ! grep -Fxq -- '- Installed codesign: `valid`' "$evidence"; then
    evidence_reasons+=("installed app code signature is not recorded as valid")
  fi
  if ! grep -Fxq -- '- Installed hardened runtime: `true`' "$evidence"; then
    evidence_reasons+=("installed app hardened runtime is not recorded as enabled")
  fi
  if ! grep -Fxq -- '- Installed CLI executable: `true`' "$evidence"; then
    evidence_reasons+=("installed bundled CLI is not recorded as executable")
  fi
  if ! grep -Fxq -- '- Installed Codex skill: `present`' "$evidence"; then
    evidence_reasons+=("installed bundled Codex skill is not recorded as present")
  fi

  for label in "${required_checked_labels[@]}"; do
    if ! is_checked "$evidence" "$label"; then
      evidence_reasons+=("unchecked: $label")
    fi
  done

  if ! grep -Fq 'Raw audio files: `0`' "$evidence"; then
    evidence_reasons+=("raw audio file count is not zero")
  fi

  if [[ "${#evidence_reasons[@]}" -eq 0 ]]; then
    completed_manual_evidence="$evidence"
    break
  fi

  evidence_failure_details+=("$evidence")
  for reason in "${evidence_reasons[@]}"; do
    evidence_failure_details+=("  - $reason")
  done
done

if [[ -z "$completed_manual_evidence" ]]; then
  echo "manual_qa_evidence_checked=${#MANUAL_QA_EVIDENCE[@]}" >&2
  printf '%s\n' "${evidence_failure_details[@]}" >&2
  fail "no provided manual QA evidence file matches the current app package SHA and shows all required manual, CLI/Codex, diagnostics, feedback, and raw-audio cleanup checks complete"
fi

echo "production_ready=true"
echo "dist=$DIST_DIR"
echo "manual_qa_evidence=$completed_manual_evidence"

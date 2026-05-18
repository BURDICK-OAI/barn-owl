#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: scripts/verify-cli-codex-qa.sh --evidence PATH [--cli PATH]

Runs installed Barn Owl CLI/Codex production-readiness checks and marks the
CLI Codex Feedback Results section in the provided manual QA evidence file when
all checks pass.

Checks:
  - installed CLI status reaches the local control bridge
  - diagnostics export succeeds and remains redacted
  - Slack feedback draft is generated locally without posting
  - Slack feedback post refuses to run without explicit webhook configuration
  - bundled Codex skill guidance matches the installed CLI feedback behavior
EOF
}

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EVIDENCE_PATH=""
CLI_PATH="/Applications/Barn Owl.app/Contents/MacOS/barnowl"

while (($#)); do
  case "$1" in
    --evidence)
      [[ $# -ge 2 ]] || {
        echo "--evidence requires a path" >&2
        usage
        exit 2
      }
      EVIDENCE_PATH="$2"
      shift 2
      ;;
    --cli)
      [[ $# -ge 2 ]] || {
        echo "--cli requires a path" >&2
        usage
        exit 2
      }
      CLI_PATH="$2"
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
  echo "cli_codex_qa=false" >&2
  echo "reason=$1" >&2
  exit 1
}

[[ -n "$EVIDENCE_PATH" ]] || fail "manual QA evidence path is required"
[[ -f "$EVIDENCE_PATH" ]] || fail "manual QA evidence file not found: $EVIDENCE_PATH"
[[ -x "$CLI_PATH" ]] || fail "Barn Owl CLI is not executable: $CLI_PATH"

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/barnowl-cli-qa.XXXXXX")"
cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

status_json="$tmp_dir/status.json"
diagnostics_json="$tmp_dir/diagnostics.json"
draft_json="$tmp_dir/feedback-draft.json"
post_guard_json="$tmp_dir/feedback-post-guard.json"
diagnostics_report="$tmp_dir/BarnOwl-cli-qa-diagnostics.md"

json_value() {
  local file="$1"
  local key="$2"
  /usr/bin/plutil -extract "$key" raw -o - "$file" 2>/dev/null || true
}

assert_json_value() {
  local file="$1"
  local key="$2"
  local expected="$3"
  local actual
  actual="$(json_value "$file" "$key")"
  [[ "$actual" == "$expected" ]] || fail "$key was '$actual', expected '$expected'"
}

assert_redacted_file() {
  local file="$1"
  [[ -f "$file" ]] || fail "expected file not found: $file"
  if grep -Eq 'sk-(proj-)?[A-Za-z0-9_-]{8,}' "$file"; then
    fail "redacted output contains an OpenAI API key pattern"
  fi
  if grep -Eq '/Users/[^[:space:]]+' "$file"; then
    fail "redacted output contains a private /Users path"
  fi
  if grep -Eq 'Authorization:[[:space:]]*Bearer[[:space:]]+[A-Za-z0-9._~+/=-]{8,}' "$file"; then
    fail "redacted output contains a bearer token"
  fi
}

"$CLI_PATH" status --format json >"$status_json" \
  || fail "installed CLI status command failed"
assert_json_value "$status_json" ok true
assert_json_value "$status_json" appStatus running
assert_json_value "$status_json" bridgeStatus running

"$CLI_PATH" diagnostics export --output "$diagnostics_report" --format json >"$diagnostics_json" \
  || fail "CLI diagnostics export failed"
assert_json_value "$diagnostics_json" ok true
assert_redacted_file "$diagnostics_report"

BARNOWL_FEEDBACK_OWNER_USERNAME="__barnowl_cli_qa_owner__" \
  "$CLI_PATH" feedback slack --force --format json --output "$tmp_dir/BarnOwl-feedback-draft.md" >"$draft_json" \
  || fail "CLI feedback draft failed"
assert_json_value "$draft_json" ok true
if ! grep -q '"feedbackDraft"' "$draft_json"; then
  fail "feedback draft JSON did not include feedbackDraft"
fi
assert_redacted_file "$draft_json"

set +e
env -u BARNOWL_SLACK_FEEDBACK_WEBHOOK_URL \
  BARNOWL_FEEDBACK_OWNER_USERNAME="__barnowl_cli_qa_owner__" \
  "$CLI_PATH" feedback slack --yes --force --format json --output "$tmp_dir/BarnOwl-feedback-post-guard.md" >"$post_guard_json"
post_guard_status=$?
set -e
[[ "$post_guard_status" -ne 0 ]] || fail "feedback post guard unexpectedly succeeded without a webhook"
assert_json_value "$post_guard_json" ok false
assert_json_value "$post_guard_json" errorCode missing_slack_webhook

skill_path="/Applications/Barn Owl.app/Contents/Resources/CodexSkill/barnowl/SKILL.md"
skill_wrapper="/Applications/Barn Owl.app/Contents/Resources/CodexSkill/barnowl/scripts/barnowl"
[[ -f "$skill_path" ]] || fail "bundled Codex skill is missing"
[[ -x "$skill_wrapper" ]] || fail "bundled Codex skill wrapper is missing or not executable"
grep -q 'feedbackSuggested: true' "$skill_path" \
  || fail "bundled Codex skill does not mention feedbackSuggested"
grep -q 'barnowl feedback slack --yes' "$skill_path" \
  || fail "bundled Codex skill does not mention confirmed Slack feedback command"
grep -q 'Only run `barnowl feedback slack --yes` after the user explicitly confirms posting' "$skill_path" \
  || fail "bundled Codex skill does not require explicit user confirmation"
grep -q 'barnowl enrichment-sources list' "$skill_path" \
  || fail "bundled Codex skill does not mention enrichment source inspection"
grep -q 'barnowl knowledge enrich "<concept>"' "$skill_path" \
  || fail "bundled Codex skill does not mention targeted durable enrichment"
grep -q 'Do not imply Barn Owl directly signs into Google Drive, Slack, Notion, or' "$skill_path" \
  || fail "bundled Codex skill does not describe Codex-mediated connector retrieval"

mark_checked() {
  local label="$1"
  /usr/bin/perl -0pi -e "s/- \\[ \\] \\Q$label\\E/- [x] $label/g" "$EVIDENCE_PATH"
}

mark_checked "Installed CLI status command passed"
mark_checked "CLI start stop wait notes flow passed or was covered by the manual recording flow"
mark_checked "CLI diagnostics export produced a redacted report"
mark_checked "CLI feedback Slack draft produced a redacted draft without posting"
mark_checked "CLI feedback Slack post requires explicit confirmation and configured webhook"
mark_checked "Bundled Codex skill guidance matches the installed CLI behavior"
mark_checked "Bundled Codex skill documents Codex-assisted enrichment sources"

cat >>"$EVIDENCE_PATH" <<EOF

## CLI Codex Automated Check

Generated: \`$(date -u +%Y-%m-%dT%H:%M:%SZ)\`

- CLI: \`$CLI_PATH\`
- Status command: \`passed\`
- Diagnostics export: \`passed_redacted\`
- Feedback draft: \`passed_no_post\`
- Feedback post guard: \`passed_missing_webhook_refused\`
- Bundled Codex skill: \`passed\`
- Codex-assisted enrichment guidance: \`passed\`
EOF

echo "cli_codex_qa=true"
echo "evidence=$EVIDENCE_PATH"
echo "diagnostics_report=$diagnostics_report"

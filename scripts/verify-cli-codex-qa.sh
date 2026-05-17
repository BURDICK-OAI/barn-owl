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
  - bundled Codex MCP app resources exist and boot as a local MCP endpoint

This script does not start or stop a live recording. The manual release-candidate
capture pass is responsible for checking the recording workflow box in the
evidence file.
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
MCP_PID=""
cleanup() {
  if [[ -n "$MCP_PID" ]]; then
    kill "$MCP_PID" >/dev/null 2>&1 || true
    wait "$MCP_PID" 2>/dev/null || true
  fi
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

status_json="$tmp_dir/status.json"
diagnostics_json="$tmp_dir/diagnostics.json"
draft_json="$tmp_dir/feedback-draft.json"
post_guard_json="$tmp_dir/feedback-post-guard.json"
diagnostics_report="$tmp_dir/BarnOwl-cli-qa-diagnostics.md"
mcp_health="$tmp_dir/mcp-health.txt"
mcp_initialize="$tmp_dir/mcp-initialize.json"
mcp_tools="$tmp_dir/mcp-tools.json"
mcp_resources="$tmp_dir/mcp-resources.json"

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
mcp_app_dir="/Applications/Barn Owl.app/Contents/Resources/CodexMCPApp"
mcp_server="$mcp_app_dir/server.js"
mcp_client="$mcp_app_dir/lib/barnowl-client.js"
mcp_capability_adapter="$mcp_app_dir/lib/codex-capability-adapter.js"
mcp_widget="$mcp_app_dir/public/barnowl-widget.html"
[[ -f "$skill_path" ]] || fail "bundled Codex skill is missing"
[[ -x "$skill_wrapper" ]] || fail "bundled Codex skill wrapper is missing or not executable"
[[ -f "$mcp_server" ]] || fail "bundled Codex MCP app server is missing"
[[ -f "$mcp_client" ]] || fail "bundled Codex MCP app bridge client is missing"
[[ -f "$mcp_capability_adapter" ]] || fail "bundled Codex MCP capability adapter is missing"
[[ -f "$mcp_widget" ]] || fail "bundled Codex MCP app widget is missing"
grep -q 'feedbackSuggested: true' "$skill_path" \
  || fail "bundled Codex skill does not mention feedbackSuggested"
grep -q 'barnowl feedback slack --yes' "$skill_path" \
  || fail "bundled Codex skill does not mention confirmed Slack feedback command"
grep -q 'Only run `barnowl feedback slack --yes` after the user explicitly confirms posting' "$skill_path" \
  || fail "bundled Codex skill does not require explicit user confirmation"
grep -q 'barnowl stop --wait-review --timeout 10m' "$skill_path" \
  || fail "bundled Codex skill does not prefer the review-aware stop flow"
grep -q 'barnowl wait --session <uuid> --until review --timeout 10m' "$skill_path" \
  || fail "bundled Codex skill does not document review waits"
grep -q 'barnowl meeting context-review <meeting-id>' "$skill_path" \
  || fail "bundled Codex skill does not document meeting context review retrieval"
grep -q 'barnowl meeting context-review accept-suggestion <meeting-id> <suggestion-id>' "$skill_path" \
  || fail "bundled Codex skill does not document Context Library suggestion acceptance"
grep -q 'barnowl meeting context-review ignore-suggestion <meeting-id> <suggestion-id>' "$skill_path" \
  || fail "bundled Codex skill does not document Context Library suggestion rejection"
grep -q 'barnowl context-library add --type person --name "Collin Burdick" --alias "Colin Burdick"' "$skill_path" \
  || fail "bundled Codex skill does not document Context Library creation"
grep -q 'barnowl context-library list --type person --query "Collin"' "$skill_path" \
  || fail "bundled Codex skill does not document Context Library search"

node_bin="${NODE_BIN:-$(command -v node || true)}"
[[ -n "$node_bin" && -x "$node_bin" ]] || fail "node is required for installed Codex MCP app smoke"

mcp_port="${BARNOWL_MCP_QA_PORT:-8898}"
HOST=127.0.0.1 \
PORT="$mcp_port" \
BARNOWL_BRIDGE_URL="http://127.0.0.1:1" \
  "$node_bin" "$mcp_server" >"$tmp_dir/mcp-server.log" 2>&1 &
MCP_PID=$!

mcp_ready=0
for _ in $(seq 1 40); do
  if /usr/bin/curl -fsS "http://127.0.0.1:$mcp_port/" >"$mcp_health" 2>/dev/null; then
    mcp_ready=1
    break
  fi
  sleep 0.1
done
[[ "$mcp_ready" -eq 1 ]] || fail "bundled Codex MCP app server did not become ready"
grep -Fxq 'Barn Owl MCP server' "$mcp_health" \
  || fail "bundled Codex MCP app health endpoint returned unexpected content"

/usr/bin/curl -fsS \
  -H 'content-type: application/json' \
  --data '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
  "http://127.0.0.1:$mcp_port/mcp" >"$mcp_initialize" \
  || fail "bundled Codex MCP app initialize request failed"
grep -q '"name":"barnowl"' "$mcp_initialize" \
  || fail "bundled Codex MCP app initialize response is missing server info"

/usr/bin/curl -fsS \
  -H 'content-type: application/json' \
  --data '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' \
  "http://127.0.0.1:$mcp_port/mcp" >"$mcp_tools" \
  || fail "bundled Codex MCP app tools/list request failed"
grep -q '"name":"render_barnowl_dashboard"' "$mcp_tools" \
  || fail "bundled Codex MCP app does not expose render_barnowl_dashboard"

/usr/bin/curl -fsS \
  -H 'content-type: application/json' \
  --data '{"jsonrpc":"2.0","id":3,"method":"resources/list","params":{}}' \
  "http://127.0.0.1:$mcp_port/mcp" >"$mcp_resources" \
  || fail "bundled Codex MCP app resources/list request failed"
grep -q 'ui://widget/barnowl-dashboard-v1.html' "$mcp_resources" \
  || fail "bundled Codex MCP app widget resource is missing"

mark_checked() {
  local label="$1"
  /usr/bin/perl -0pi -e "s/- \\[ \\] \\Q$label\\E/- [x] $label/g" "$EVIDENCE_PATH"
}

mark_checked "Installed CLI status command passed"
mark_checked "CLI diagnostics export produced a redacted report"
mark_checked "CLI feedback Slack draft produced a redacted draft without posting"
mark_checked "CLI feedback Slack post requires explicit confirmation and configured webhook"
mark_checked "Bundled Codex skill guidance matches the installed CLI behavior"
mark_checked "Bundled Codex MCP app resources are present"
mark_checked "Installed Codex MCP app smoke passed"

cat >>"$EVIDENCE_PATH" <<EOF

## CLI Codex Automated Check

Generated: \`$(date -u +%Y-%m-%dT%H:%M:%SZ)\`

- CLI: \`$CLI_PATH\`
- Status command: \`passed\`
- Recording workflow: \`not_exercised_here_manual_capture_pass_required\`
- Diagnostics export: \`passed_redacted\`
- Feedback draft: \`passed_no_post\`
- Feedback post guard: \`passed_missing_webhook_refused\`
- Bundled Codex skill: \`passed\`
- Bundled Codex MCP app: \`passed_local_mcp_smoke\`
EOF

echo "cli_codex_qa=true"
echo "evidence=$EVIDENCE_PATH"
echo "diagnostics_report=$diagnostics_report"

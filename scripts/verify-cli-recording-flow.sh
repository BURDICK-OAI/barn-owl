#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: scripts/verify-cli-recording-flow.sh --evidence PATH [options]

Runs the installed Barn Owl CLI control-path smoke against a real app session:
  - start a recording
  - let it run briefly
  - stop it
  - wait until final processing is complete
  - fetch meeting notes

On success, the script marks the matching checkbox in the provided manual QA
evidence file and appends a compact, transcript-free proof section.

Options:
  --cli PATH        CLI binary to use. Defaults to the installed app CLI.
  --duration SEC    Recording dwell time before stop. Defaults to 3.
  --timeout VALUE   Wait timeout passed to `barnowl wait`. Defaults to 5m.
  --title VALUE     Optional smoke-test meeting title.
EOF
}

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EVIDENCE_PATH=""
CLI_PATH="/Applications/Barn Owl.app/Contents/MacOS/barnowl"
DURATION_SECONDS="3"
WAIT_TIMEOUT="5m"
TITLE="CLI Recording Flow Smoke"

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
    --duration)
      [[ $# -ge 2 ]] || {
        echo "--duration requires a value" >&2
        usage
        exit 2
      }
      DURATION_SECONDS="$2"
      shift 2
      ;;
    --timeout)
      [[ $# -ge 2 ]] || {
        echo "--timeout requires a value" >&2
        usage
        exit 2
      }
      WAIT_TIMEOUT="$2"
      shift 2
      ;;
    --title)
      [[ $# -ge 2 ]] || {
        echo "--title requires a value" >&2
        usage
        exit 2
      }
      TITLE="$2"
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
  echo "cli_recording_flow=false" >&2
  echo "reason=$1" >&2
  exit 1
}

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

mark_checked() {
  local label="$1"
  /usr/bin/perl -0pi -e "s/- \\[ \\] \\Q$label\\E/- [x] $label/g" "$EVIDENCE_PATH"
}

[[ -n "$EVIDENCE_PATH" ]] || fail "manual QA evidence path is required"
[[ -f "$EVIDENCE_PATH" ]] || fail "manual QA evidence file not found: $EVIDENCE_PATH"
[[ -x "$CLI_PATH" ]] || fail "Barn Owl CLI is not executable: $CLI_PATH"
[[ "$DURATION_SECONDS" =~ ^[0-9]+([.][0-9]+)?$ ]] || fail "--duration must be numeric seconds"

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/barnowl-cli-recording-flow.XXXXXX")"
cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

start_json="$tmp_dir/start.json"
stop_json="$tmp_dir/stop.json"
wait_json="$tmp_dir/wait.json"
notes_json="$tmp_dir/notes.json"

"$CLI_PATH" --format json start --title "$TITLE" --type "General Discussion" >"$start_json" \
  || fail "CLI start command failed"
assert_json_value "$start_json" ok true

session_id="$(json_value "$start_json" sessionID)"
[[ -n "$session_id" ]] || {
  capture_status="$(json_value "$start_json" captureStatus)"
  next_command="$(json_value "$start_json" nextCommand)"
  case "$capture_status" in
    "Requesting microphone permission."|"Requesting system audio permission."|"Requesting capture permission.")
      fail "CLI start is blocked on macOS permission interaction (captureStatus='$capture_status', nextCommand='$next_command')"
      ;;
  esac
  fail "CLI start did not reach an active recording (captureStatus='$capture_status', nextCommand='$next_command')"
}
assert_json_value "$start_json" recordingStatus recording

sleep "$DURATION_SECONDS"

"$CLI_PATH" --format json stop >"$stop_json" \
  || fail "CLI stop command failed"
assert_json_value "$stop_json" ok true

"$CLI_PATH" --format json wait --session "$session_id" --until complete --timeout "$WAIT_TIMEOUT" >"$wait_json" \
  || fail "CLI wait command failed"
assert_json_value "$wait_json" ok true

"$CLI_PATH" --format json meeting notes "$session_id" >"$notes_json" \
  || fail "CLI meeting notes command failed"
assert_json_value "$notes_json" ok true

mark_checked "CLI start stop wait notes flow passed or was covered by the manual recording flow"

cat >>"$EVIDENCE_PATH" <<EOF

## CLI Live Recording Flow

Generated: \`$(date -u +%Y-%m-%dT%H:%M:%SZ)\`

- CLI: \`$CLI_PATH\`
- Session: \`$session_id\`
- Start: \`passed_recording_started\`
- Stop: \`passed_stop_requested\`
- Wait: \`passed_until_complete\`
- Notes retrieval: \`passed\`
- Privacy note: transcript and notes content were intentionally omitted from this evidence file.
EOF

echo "cli_recording_flow=true"
echo "evidence=$EVIDENCE_PATH"
echo "session=$session_id"

#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: scripts/register-codex-mcp-app.sh [--name NAME] [--url URL] [--replace]

Registers the Barn Owl streamable-HTTP MCP app with the local Codex CLI.
Existing correct registrations are left alone. Existing mismatched registrations
are preserved unless --replace is passed.
EOF
}

NAME="barnowl"
URL="http://127.0.0.1:8787/mcp"
REPLACE=0

while (($#)); do
  case "$1" in
    --name)
      [[ $# -ge 2 ]] || {
        echo "--name requires a value" >&2
        usage
        exit 2
      }
      NAME="$2"
      shift 2
      ;;
    --url)
      [[ $# -ge 2 ]] || {
        echo "--url requires a value" >&2
        usage
        exit 2
      }
      URL="$2"
      shift 2
      ;;
    --replace)
      REPLACE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 2
      ;;
  esac
done

fail() {
  echo "codex_mcp_registration=false" >&2
  echo "reason=$1" >&2
  exit 1
}

command -v codex >/dev/null 2>&1 || fail "codex CLI is required"
command -v python3 >/dev/null 2>&1 || fail "python3 is required"

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/barnowl-codex-mcp-register.XXXXXX")"
cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

existing_json="$tmp_dir/existing.json"
verified_json="$tmp_dir/verified.json"

current_url() {
  python3 - "$1" <<'PY'
import json
import sys

payload = json.load(open(sys.argv[1], encoding="utf-8"))
transport = payload.get("transport") or {}
print(transport.get("url") or "")
PY
}

current_type() {
  python3 - "$1" <<'PY'
import json
import sys

payload = json.load(open(sys.argv[1], encoding="utf-8"))
transport = payload.get("transport") or {}
print(transport.get("type") or "")
PY
}

current_enabled() {
  python3 - "$1" <<'PY'
import json
import sys

payload = json.load(open(sys.argv[1], encoding="utf-8"))
print("true" if payload.get("enabled") is True else "false")
PY
}

if codex mcp get "$NAME" --json >"$existing_json" 2>/dev/null; then
  EXISTING_URL="$(current_url "$existing_json")"
  EXISTING_TYPE="$(current_type "$existing_json")"
  EXISTING_ENABLED="$(current_enabled "$existing_json")"

  if [[ "$EXISTING_URL" == "$URL" && "$EXISTING_TYPE" == "streamable_http" && "$EXISTING_ENABLED" == "true" ]]; then
    echo "codex_mcp_registration=true"
    echo "action=already_registered"
    echo "name=$NAME"
    echo "url=$URL"
    exit 0
  fi

  if [[ "$REPLACE" -ne 1 ]]; then
    fail "existing Codex MCP registration for $NAME differs; rerun with --replace to overwrite it"
  fi

  codex mcp remove "$NAME" >/dev/null
fi

codex mcp add "$NAME" --url "$URL" >/dev/null
codex mcp get "$NAME" --json >"$verified_json" 2>/dev/null \
  || fail "registration was added but could not be read back"

VERIFIED_URL="$(current_url "$verified_json")"
VERIFIED_TYPE="$(current_type "$verified_json")"
VERIFIED_ENABLED="$(current_enabled "$verified_json")"
[[ "$VERIFIED_URL" == "$URL" ]] || fail "registered URL mismatch: $VERIFIED_URL"
[[ "$VERIFIED_TYPE" == "streamable_http" ]] || fail "registered transport mismatch: $VERIFIED_TYPE"
[[ "$VERIFIED_ENABLED" == "true" ]] || fail "registered server is not enabled"

echo "codex_mcp_registration=true"
echo "action=registered"
echo "name=$NAME"
echo "url=$URL"

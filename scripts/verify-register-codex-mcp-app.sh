#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/barnowl-register-mcp-check.XXXXXX")"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

cat >"$TMP_DIR/codex" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

STATE_FILE="${BARNOWL_FAKE_CODEX_STATE:?missing fake state path}"
mkdir -p "$(dirname "$STATE_FILE")"

case "$1 $2" in
  "mcp get")
    NAME="$3"
    shift 3
    if [[ ! -f "$STATE_FILE" ]]; then
      exit 1
    fi
    cat "$STATE_FILE"
    ;;
  "mcp add")
    NAME="$3"
    shift 3
    [[ "$1" == "--url" ]] || exit 2
    URL="$2"
    cat >"$STATE_FILE" <<JSON
{
  "name": "$NAME",
  "enabled": true,
  "transport": {
    "type": "streamable_http",
    "url": "$URL"
  }
}
JSON
    ;;
  "mcp remove")
    rm -f "$STATE_FILE"
    ;;
  *)
    echo "unexpected fake codex command: $*" >&2
    exit 2
    ;;
esac
EOF
chmod +x "$TMP_DIR/codex"

export PATH="$TMP_DIR:$PATH"
export BARNOWL_FAKE_CODEX_STATE="$TMP_DIR/state.json"

OUT1="$("$ROOT_DIR/scripts/register-codex-mcp-app.sh")"
grep -Fxq 'codex_mcp_registration=true' <<<"$OUT1"
grep -Fxq 'action=registered' <<<"$OUT1"

OUT2="$("$ROOT_DIR/scripts/register-codex-mcp-app.sh")"
grep -Fxq 'codex_mcp_registration=true' <<<"$OUT2"
grep -Fxq 'action=already_registered' <<<"$OUT2"

python3 - "$BARNOWL_FAKE_CODEX_STATE" <<'PY'
import json
import sys

path = sys.argv[1]
payload = json.load(open(path, encoding="utf-8"))
payload["transport"]["url"] = "http://127.0.0.1:9999/mcp"
json.dump(payload, open(path, "w", encoding="utf-8"))
PY

if "$ROOT_DIR/scripts/register-codex-mcp-app.sh" >"$TMP_DIR/mismatch.out" 2>"$TMP_DIR/mismatch.err"; then
  echo "mismatched registration should require --replace" >&2
  exit 1
fi
grep -Fq 'rerun with --replace' "$TMP_DIR/mismatch.err"

OUT3="$("$ROOT_DIR/scripts/register-codex-mcp-app.sh" --replace)"
grep -Fxq 'codex_mcp_registration=true' <<<"$OUT3"
grep -Fxq 'action=registered' <<<"$OUT3"

echo "register_codex_mcp_app_check=true"

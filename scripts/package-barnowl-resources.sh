#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="${1:?Usage: scripts/package-barnowl-resources.sh /path/to/BarnOwl.app}"

if [[ ! -d "$APP_PATH" ]]; then
  echo "Barn Owl app not found: $APP_PATH" >&2
  exit 1
fi

MACOS_DIR="$APP_PATH/Contents/MacOS"
SKILL_DIR="$APP_PATH/Contents/Resources/CodexSkill/barnowl"
MCP_APP_DIR="$APP_PATH/Contents/Resources/CodexMCPApp"

/bin/mkdir -p "$MACOS_DIR" "$SKILL_DIR/scripts" "$MCP_APP_DIR/lib" "$MCP_APP_DIR/public"
/bin/cp "$ROOT_DIR/scripts/barnowl" "$MACOS_DIR/barnowl"
/bin/cp "$ROOT_DIR/skills/barnowl/SKILL.md" "$SKILL_DIR/SKILL.md"
/bin/cp "$ROOT_DIR/skills/barnowl/scripts/barnowl" "$SKILL_DIR/scripts/barnowl"
/bin/cp "$ROOT_DIR/mcp-app/package.json" "$MCP_APP_DIR/package.json"
/bin/cp "$ROOT_DIR/mcp-app/server.js" "$MCP_APP_DIR/server.js"
/bin/cp "$ROOT_DIR/mcp-app/lib/barnowl-client.js" "$MCP_APP_DIR/lib/barnowl-client.js"
/bin/cp "$ROOT_DIR/mcp-app/lib/codex-capability-adapter.js" "$MCP_APP_DIR/lib/codex-capability-adapter.js"
/bin/cp "$ROOT_DIR/mcp-app/public/barnowl-widget.html" "$MCP_APP_DIR/public/barnowl-widget.html"
/bin/chmod +x "$MACOS_DIR/barnowl" "$SKILL_DIR/scripts/barnowl"

echo "Packaged Barn Owl CLI, Codex skill, and MCP app into: $APP_PATH"

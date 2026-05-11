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

/bin/mkdir -p "$MACOS_DIR" "$SKILL_DIR/scripts"
/bin/cp "$ROOT_DIR/scripts/barnowl" "$MACOS_DIR/barnowl"
/bin/cp "$ROOT_DIR/skills/barnowl/SKILL.md" "$SKILL_DIR/SKILL.md"
/bin/cp "$ROOT_DIR/skills/barnowl/scripts/barnowl" "$SKILL_DIR/scripts/barnowl"
/bin/chmod +x "$MACOS_DIR/barnowl" "$SKILL_DIR/scripts/barnowl"

echo "Packaged Barn Owl CLI and Codex skill into: $APP_PATH"

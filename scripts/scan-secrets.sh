#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="${1:-"$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"}"

if ! command -v rg >/dev/null 2>&1; then
  cat >&2 <<'EOF'
rg is required for secret scanning.

Install ripgrep before running Barn Owl release scripts locally:
  brew install ripgrep

The GitHub release workflow installs ripgrep on its macOS runner.
EOF
  exit 1
fi

patterns=(
  'sk-(proj-)?[A-Za-z0-9_-]{24,}'
  '(OPENAI_API_KEY|BARNOWL_API_KEY_TO_INSTALL)[[:space:]]*=[[:space:]]*["'\'']?[^#[:space:]"'\'']+'
  '-----BEGIN (RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----'
  'gh[pousr]_[A-Za-z0-9_]{36,}'
  'xox[baprs]-[A-Za-z0-9-]{20,}'
)

for pattern in "${patterns[@]}"; do
  if rg -n --hidden \
    --glob '!**/.git/**' \
    --glob '!**/.env.example' \
    --glob '!**/.tools/**' \
    --glob '!**/.build/**' \
    --glob '!**/DerivedData/**' \
    --glob '!**/build/**' \
    --glob '!**/dist/**' \
    --glob '!**/*.xcuserstate' \
    --glob '!**/*.xcuserdata/**' \
    -- "$pattern" "$ROOT_DIR"; then
    echo "Refusing to continue: possible secret found." >&2
    exit 1
  fi
done

#!/bin/sh
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUNDLED_XCODEGEN="$ROOT/.tools/xcodegen/xcodegen/bin/xcodegen"

if [ -x "$BUNDLED_XCODEGEN" ]; then
  exec "$BUNDLED_XCODEGEN" "$@"
fi

if command -v xcodegen >/dev/null 2>&1; then
  exec xcodegen "$@"
fi

cat >&2 <<'EOF'
XcodeGen is required to regenerate BarnOwl.xcodeproj.

Install it with one of:
  brew install xcodegen
  mint install yonaskolb/XcodeGen

Then rerun the command.
EOF
exit 1

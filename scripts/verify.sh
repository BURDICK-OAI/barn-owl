#!/bin/sh
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

scripts/scan-secrets.sh
if scripts/xcodegen.sh generate; then
  :
elif [ -f BarnOwl.xcodeproj/project.pbxproj ]; then
  cat >&2 <<'EOF'
Warning: XcodeGen is unavailable, so scripts/verify.sh is using the checked-in
BarnOwl.xcodeproj. Install XcodeGen to regenerate the project from project.yml.
EOF
else
  exit 1
fi
xcodebuild clean -scheme BarnOwl -derivedDataPath DerivedData CODE_SIGN_IDENTITY=-
xcodebuild test -scheme BarnOwl -destination 'platform=macOS' -derivedDataPath DerivedData CODE_SIGN_IDENTITY=-

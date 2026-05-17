#!/bin/sh
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
HOSTED_DERIVED_DATA_PATH="${HOSTED_DERIVED_DATA_PATH:-"$ROOT/DerivedDataHostedUnsigned"}"
export HOSTED_DERIVED_DATA_PATH

scripts/scan-secrets.sh
scripts/verify-notary-profile-resolver.sh
scripts/verify-barnowl-cli-start-timeout.sh
scripts/verify-barnowl-cli-mcp-autostart.sh
scripts/verify-register-codex-mcp-app.sh
scripts/verify-barnowl-cli-stop-review.sh
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
xcodebuild build-for-testing -scheme BarnOwl -destination 'platform=macOS' -derivedDataPath DerivedData CODE_SIGN_IDENTITY=-
xcodebuild build-for-testing \
  -scheme BarnOwlAppHostedTests \
  -destination 'platform=macOS' \
  -derivedDataPath "$HOSTED_DERIVED_DATA_PATH" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY=

for bundle in \
  DerivedData/Build/Products/Debug/BarnOwlCoreTests.xctest \
  DerivedData/Build/Products/Debug/BarnOwlAudioTests.xctest \
  DerivedData/Build/Products/Debug/BarnOwlOpenAITests.xctest \
  DerivedData/Build/Products/Debug/BarnOwlTranscriptionTests.xctest \
  DerivedData/Build/Products/Debug/BarnOwlContextTests.xctest \
  DerivedData/Build/Products/Debug/BarnOwlNotesTests.xctest \
  DerivedData/Build/Products/Debug/BarnOwlPersistenceTests.xctest
do
  xcrun xctest "$bundle"
done

scripts/run-hosted-app-tests.sh

command -v node >/dev/null 2>&1 \
  || {
    echo "node is required to run the Barn Owl Codex MCP app verification suite." >&2
    exit 1
  }
(
  cd "$ROOT/mcp-app"
  node --test tests/*.test.js
)

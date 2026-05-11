#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED_DATA_PATH="${BARNOWL_DERIVED_DATA:-"$ROOT_DIR/DerivedData"}"
CONFIGURATION="${BARNOWL_CONFIGURATION:-Release}"
APP_PATH="$DERIVED_DATA_PATH/Build/Products/$CONFIGURATION/BarnOwl.app"
INSTALLED_APP="/Applications/Barn Owl.app"

read_plist_value() {
  local plist="$1"
  local key="$2"
  /usr/libexec/PlistBuddy -c "Print :$key" "$plist" 2>/dev/null || true
}

numeric_or_zero() {
  local value="$1"
  if [[ "$value" =~ '^[0-9]+$' ]]; then
    echo "$value"
  else
    echo "0"
  fi
}

echo "Building Barn Owl local update..."
if [[ -d "$APP_PATH" ]]; then
  /bin/rm -rf "$APP_PATH"
fi
/usr/bin/xcodebuild \
  -scheme BarnOwl \
  -configuration "$CONFIGURATION" \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  -quiet \
  build

if [[ ! -d "$APP_PATH" ]]; then
  echo "Build succeeded, but app bundle was not found: $APP_PATH" >&2
  exit 1
fi

INFO_PLIST="$APP_PATH/Contents/Info.plist"
BUILT_BUILD="$(numeric_or_zero "$(read_plist_value "$INFO_PLIST" CFBundleVersion)")"
INSTALLED_BUILD="0"
if [[ -f "$INSTALLED_APP/Contents/Info.plist" ]]; then
  INSTALLED_BUILD="$(numeric_or_zero "$(read_plist_value "$INSTALLED_APP/Contents/Info.plist" CFBundleVersion)")"
fi

NEXT_BUILD=$(( BUILT_BUILD > INSTALLED_BUILD ? BUILT_BUILD + 1 : INSTALLED_BUILD + 1 ))
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $NEXT_BUILD" "$INFO_PLIST"

"$ROOT_DIR/scripts/package-barnowl-resources.sh" "$APP_PATH"
/usr/bin/codesign --force --deep --options runtime --sign - "$APP_PATH"
"$ROOT_DIR/scripts/publish-local-update.sh" "$APP_PATH"

if [[ "${BARNOWL_KEEP_BUILD_APP:-0}" != "1" ]]; then
  /bin/rm -rf "$APP_PATH"
fi

echo ""
echo "Local Barn Owl update is ready."
echo "Current installed build: $INSTALLED_BUILD"
echo "Published update build: $NEXT_BUILD"
echo "Open Barn Owl menu bar > Update to install it."
if [[ "${BARNOWL_KEEP_BUILD_APP:-0}" != "1" ]]; then
  echo "Cleaned generated debug app bundle to avoid duplicate Barn Owl apps."
fi

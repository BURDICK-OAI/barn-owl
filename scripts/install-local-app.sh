#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: scripts/install-local-app.sh --yes [--app-zip PATH] [--destination PATH] [--reset-state] [--launch] [--skip-verify]

Installs a packaged Barn Owl app zip into /Applications, or another destination
path, for local/internal testing. Normal installs preserve Barn Owl recordings,
notes, settings, and Keychain data. This is not a signing or notarization bypass:
the app package is verified before installation unless --skip-verify is passed.

Options:
  --yes              Required. Confirms replacement of the destination app.
  --app-zip PATH     App zip to install. Defaults to dist/BarnOwl.app.zip.
  --destination PATH Destination .app path. Defaults to /Applications/Barn Owl.app.
  --reset-state      Destructive test-only reset before install. Deletes local
                     Barn Owl data/keychain/TCC decisions for fresh onboarding QA.
  --launch           Launch Barn Owl after installation.
  --skip-verify      Skip scripts/verify-release.sh. Intended only for debugging a broken package.
EOF
}

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_ZIP="$ROOT_DIR/dist/BarnOwl.app.zip"
DESTINATION="/Applications/Barn Owl.app"
CONFIRM=0
RESET_STATE=0
LAUNCH_APP=0
VERIFY_PACKAGE=1

while (($#)); do
  case "$1" in
    --yes)
      CONFIRM=1
      shift
      ;;
    --app-zip)
      [[ $# -ge 2 ]] || {
        echo "--app-zip requires a path" >&2
        usage
        exit 2
      }
      APP_ZIP="$2"
      shift 2
      ;;
    --destination)
      [[ $# -ge 2 ]] || {
        echo "--destination requires a path" >&2
        usage
        exit 2
      }
      DESTINATION="$2"
      shift 2
      ;;
    --reset-state)
      RESET_STATE=1
      shift
      ;;
    --launch)
      LAUNCH_APP=1
      shift
      ;;
    --skip-verify)
      VERIFY_PACKAGE=0
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
  echo "install=false" >&2
  echo "reason=$1" >&2
  exit 1
}

[[ "$CONFIRM" -eq 1 ]] || fail "pass --yes to replace the destination app"
[[ -f "$APP_ZIP" ]] || fail "app zip not found: $APP_ZIP"

if [[ "$VERIFY_PACKAGE" -eq 1 ]]; then
  "$ROOT_DIR/scripts/verify-release.sh" "$APP_ZIP" >&2
fi

if [[ "$RESET_STATE" -eq 1 ]]; then
  echo "Resetting Barn Owl local state before install (--reset-state was passed)."
  "$ROOT_DIR/scripts/reset-local-state.sh" --yes
fi

work_dir="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/barnowl-install.XXXXXX")"
cleanup() {
  /bin/rm -rf "$work_dir"
}
trap cleanup EXIT

/usr/bin/ditto -x -k "$APP_ZIP" "$work_dir"
STAGED_APP="$(/usr/bin/find "$work_dir" -maxdepth 3 -name 'BarnOwl.app' -type d | /usr/bin/head -n 1)"
[[ -n "$STAGED_APP" && -d "$STAGED_APP" ]] || fail "BarnOwl.app was not found in $APP_ZIP"

INFO_PLIST="$STAGED_APP/Contents/Info.plist"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO_PLIST" 2>/dev/null || true)"
[[ "$BUNDLE_ID" == "com.barnowl.mac" ]] || fail "unexpected bundle id in package: $BUNDLE_ID"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST" 2>/dev/null || true)"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO_PLIST" 2>/dev/null || true)"
DEST_PARENT="$(/usr/bin/dirname "$DESTINATION")"
DEST_NAME="$(/usr/bin/basename "$DESTINATION")"
BACKUP_PATH="$DEST_PARENT/$DEST_NAME.backup.$(/bin/date -u '+%Y%m%d%H%M%S')"

echo "Stopping running Barn Owl processes..."
/usr/bin/pkill -x "BarnOwlApp" 2>/dev/null || true
/usr/bin/pkill -x "Barn Owl" 2>/dev/null || true

/bin/mkdir -p "$DEST_PARENT"

if [[ -e "$DESTINATION" ]]; then
  echo "Backing up existing app to: $BACKUP_PATH"
  /bin/mv "$DESTINATION" "$BACKUP_PATH"
fi

echo "Installing Barn Owl $VERSION ($BUILD) to: $DESTINATION"
if ! /usr/bin/ditto "$STAGED_APP" "$DESTINATION"; then
  if [[ -e "$BACKUP_PATH" && ! -e "$DESTINATION" ]]; then
    /bin/mv "$BACKUP_PATH" "$DESTINATION" || true
  fi
  fail "failed to copy app to destination"
fi

/usr/bin/codesign --verify --deep --strict "$DESTINATION" >&2

if [[ "$LAUNCH_APP" -eq 1 ]]; then
  /usr/bin/open "$DESTINATION"
fi

echo "install=true"
echo "destination=$DESTINATION"
echo "version=$VERSION"
echo "build=$BUILD"
if [[ -e "$BACKUP_PATH" ]]; then
  echo "backup=$BACKUP_PATH"
fi

#!/bin/sh
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOSTED_DERIVED_DATA_PATH="${HOSTED_DERIVED_DATA_PATH:-"$ROOT/DerivedDataHostedUnsigned"}"
PRODUCTS_DIR="${1:-"$HOSTED_DERIVED_DATA_PATH/Build/Products/Debug"}"
APP_DIR="$PRODUCTS_DIR/BarnOwl.app"
APP_BIN="$APP_DIR/Contents/MacOS/BarnOwlApp"
TEST_BUNDLE="$APP_DIR/Contents/PlugIns/BarnOwlAppTests.xctest"
TEST_INJECT="$APP_DIR/Contents/Frameworks/libXCTestBundleInject.dylib"
MAIN_THREAD_CHECKER="/Applications/Xcode.app/Contents/Developer/usr/lib/libMainThreadChecker.dylib"
MACOSX_DEVELOPER_LIB="/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib"
XCODE_SHARED_FRAMEWORKS="/Applications/Xcode.app/Contents/SharedFrameworks"
XCODE_PLATFORM_FRAMEWORKS="/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/Frameworks"

for required_path in \
  "$APP_BIN" \
  "$TEST_BUNDLE" \
  "$TEST_INJECT" \
  "$MAIN_THREAD_CHECKER" \
  "$MACOSX_DEVELOPER_LIB" \
  "$XCODE_SHARED_FRAMEWORKS" \
  "$XCODE_PLATFORM_FRAMEWORKS"
do
  if [ ! -e "$required_path" ]; then
    echo "hosted app test prerequisite missing: $required_path" >&2
    exit 1
  fi
done

DYLD_LIBRARY_PATH="$PRODUCTS_DIR:$MACOSX_DEVELOPER_LIB"
DYLD_FRAMEWORK_PATH="$PRODUCTS_DIR:$XCODE_SHARED_FRAMEWORKS:$XCODE_PLATFORM_FRAMEWORKS"
DYLD_INSERT_LIBRARIES="/usr/lib/libRPAC.dylib:$TEST_INJECT:$MAIN_THREAD_CHECKER"

exec env \
  DYLD_LIBRARY_PATH="$DYLD_LIBRARY_PATH" \
  DYLD_FRAMEWORK_PATH="$DYLD_FRAMEWORK_PATH" \
  DYLD_INSERT_LIBRARIES="$DYLD_INSERT_LIBRARIES" \
  "$APP_BIN"

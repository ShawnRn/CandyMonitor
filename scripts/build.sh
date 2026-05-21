#!/usr/bin/env bash

set -euo pipefail

CONF=${1:-release}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
PROJECT_DIR="$ROOT/CandyMonitor"
PROJECT_FILE="$PROJECT_DIR/CandyMonitor.xcodeproj"
SCHEME="CandyMonitor"
PROJECT_NAME="CandyMonitor"
APP_NAME="CandyMonitor.app"
ENTITLEMENTS_FILE="$PROJECT_DIR/CandyMonitor/CandyMonitor.entitlements"
RELEASE_DIR="$ROOT/releases"
BUILD_DIR="$ROOT/.build"
ARCHIVE_DIR="$BUILD_DIR/archive"
APP_BUILD_DIR="$BUILD_DIR/apps"
DMG_WORK_DIR="$BUILD_DIR/dmg"

if [[ "$CONF" == "debug" ]]; then
  XCODE_CONF="Debug"
else
  XCODE_CONF="Release"
fi

command -v create-dmg >/dev/null 2>&1 || {
  echo "error: create-dmg is required. Install with: brew install create-dmg"
  exit 1
}

verify_sandbox_entitlement() {
  local app_bundle="$1"
  local entitlements_xml

  codesign --verify --deep --strict --verbose=2 "$app_bundle"
  entitlements_xml=$(codesign -d --entitlements :- "$app_bundle" 2>/dev/null || true)

  if ! grep -q "<key>com.apple.security.app-sandbox</key>" <<<"$entitlements_xml" ||
     ! grep -A1 "<key>com.apple.security.app-sandbox</key>" <<<"$entitlements_xml" | grep -q "<true/>"; then
    echo "error: $app_bundle is missing com.apple.security.app-sandbox=true"
    echo "error: refusing to package an app that would read a different data container"
    exit 1
  fi
}

echo "==> Reading version from Xcode settings"
XCODE_SETTINGS=$(set +o pipefail; xcodebuild -showBuildSettings -project "$PROJECT_FILE" -scheme "$SCHEME" -configuration "$XCODE_CONF" 2>/dev/null)
MARKETING_VERSION=$(echo "$XCODE_SETTINGS" | grep " MARKETING_VERSION =" | head -n 1 | awk '{print $3}')
BUILD_NUMBER=$(echo "$XCODE_SETTINGS" | grep " CURRENT_PROJECT_VERSION =" | head -n 1 | awk '{print $3}')

if [[ -z "${MARKETING_VERSION:-}" ]]; then
  MARKETING_VERSION="1.0"
fi
if [[ -z "${BUILD_NUMBER:-}" ]]; then
  BUILD_NUMBER="$(date +%Y%m%d%H)"
fi

echo "==> Version: $MARKETING_VERSION ($BUILD_NUMBER)"
mkdir -p "$RELEASE_DIR" "$ARCHIVE_DIR" "$APP_BUILD_DIR" "$DMG_WORK_DIR"

xcodebuild -resolvePackageDependencies -project "$PROJECT_FILE" -scheme "$SCHEME" -scmProvider xcode

for TARGET_ARCH in arm64 x86_64; do
  echo "=================================================="
  echo "==> Building $PROJECT_NAME for $TARGET_ARCH"
  echo "=================================================="

  ARCH_APP_BUNDLE="$APP_BUILD_DIR/${PROJECT_NAME}_${TARGET_ARCH}.app"
  ARCH_ARCHIVE_PATH="$ARCHIVE_DIR/${PROJECT_NAME}_${TARGET_ARCH}.xcarchive"
  DMG_FINAL_PATH="$RELEASE_DIR/${PROJECT_NAME}_${MARKETING_VERSION}_${TARGET_ARCH}.dmg"
  TEMP_DMG_ROOT="$BUILD_DIR/dmg-root-${TARGET_ARCH}"
  TEMP_DMG_OUTPUT="$DMG_WORK_DIR/output-${TARGET_ARCH}"

  rm -rf "$ARCH_APP_BUNDLE" "$ARCH_ARCHIVE_PATH" "$TEMP_DMG_ROOT" "$TEMP_DMG_OUTPUT" "$DMG_FINAL_PATH"

  if [[ "$XCODE_CONF" == "Debug" ]]; then
    xcodebuild build \
      -project "$PROJECT_FILE" \
      -scheme "$SCHEME" \
      -configuration "$XCODE_CONF" \
      -destination "generic/platform=macOS" \
      -scmProvider xcode \
      MARKETING_VERSION="$MARKETING_VERSION" \
      CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
      MACOSX_DEPLOYMENT_TARGET=14.0 \
      ARCHS="$TARGET_ARCH" \
      ONLY_ACTIVE_ARCH=NO \
      CODE_SIGN_IDENTITY="-" \
      CODE_SIGNING_ALLOWED=YES

    BUILT_PRODUCTS_DIR=$(xcodebuild -showBuildSettings -project "$PROJECT_FILE" -scheme "$SCHEME" -configuration "$XCODE_CONF" ARCHS="$TARGET_ARCH" 2>/dev/null | grep -m 1 " BUILT_PRODUCTS_DIR =" | awk '{$1=$1; print substr($0, index($0,$3))}')
    cp -R "$BUILT_PRODUCTS_DIR/$APP_NAME" "$ARCH_APP_BUNDLE"
  else
    xcodebuild archive \
      -project "$PROJECT_FILE" \
      -scheme "$SCHEME" \
      -configuration "$XCODE_CONF" \
      -archivePath "$ARCH_ARCHIVE_PATH" \
      -destination "generic/platform=macOS" \
      -scmProvider xcode \
      MARKETING_VERSION="$MARKETING_VERSION" \
      CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
      MACOSX_DEPLOYMENT_TARGET=14.0 \
      ARCHS="$TARGET_ARCH" \
      ONLY_ACTIVE_ARCH=NO \
      SKIP_INSTALL=NO \
      CODE_SIGN_IDENTITY="-" \
      CODE_SIGNING_ALLOWED=YES

    cp -R "$ARCH_ARCHIVE_PATH/Products/Applications/$APP_NAME" "$ARCH_APP_BUNDLE"
  fi

  echo "==> Signing app bundle for $TARGET_ARCH"
  codesign --force --deep --sign "-" --entitlements "$ENTITLEMENTS_FILE" "$ARCH_APP_BUNDLE"
  verify_sandbox_entitlement "$ARCH_APP_BUNDLE"

  mkdir -p "$TEMP_DMG_ROOT" "$TEMP_DMG_OUTPUT"
  cp -R "$ARCH_APP_BUNDLE" "$TEMP_DMG_ROOT/$APP_NAME"

  echo "==> Creating DMG: $DMG_FINAL_PATH"
  create-dmg \
    --overwrite \
    --dmg-title="$PROJECT_NAME" \
    "$TEMP_DMG_ROOT/$APP_NAME" \
    "$TEMP_DMG_OUTPUT"

  GENERATED_DMG=""
  for candidate in "$TEMP_DMG_OUTPUT/${PROJECT_NAME} ${MARKETING_VERSION}.dmg" "$TEMP_DMG_OUTPUT/${PROJECT_NAME}.dmg" "$TEMP_DMG_OUTPUT/${PROJECT_NAME}"*.dmg; do
    if [[ -f "$candidate" ]]; then
      GENERATED_DMG="$candidate"
      break
    fi
  done

  if [[ -z "$GENERATED_DMG" ]]; then
    echo "error: create-dmg did not produce a DMG for $TARGET_ARCH"
    exit 1
  fi

  mv "$GENERATED_DMG" "$DMG_FINAL_PATH"

  rm -rf "$TEMP_DMG_ROOT" "$TEMP_DMG_OUTPUT"
  echo "==> Done: $DMG_FINAL_PATH"
done

echo "==> Release artifacts are in $RELEASE_DIR"

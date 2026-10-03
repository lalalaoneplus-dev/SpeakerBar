#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="SpeakerBar"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"
MIN_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$ROOT_DIR/Info.plist")"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT_DIR/Info.plist")"
DMG_PATH="$DIST_DIR/$APP_NAME-$VERSION.dmg"
BUILD_DIR="$ROOT_DIR/.build/package"

mkdir -p "$BUILD_DIR/module-cache" "$DIST_DIR"
for arch in arm64 x86_64; do
  swiftc -O -target "$arch-apple-macos$MIN_VERSION" \
    -module-cache-path "$BUILD_DIR/module-cache" \
    -o "$BUILD_DIR/$APP_NAME-$arch" "$ROOT_DIR/main.swift" \
    -framework AppKit -framework IOBluetooth -framework AVFoundation \
    -framework CoreAudio -framework Carbon -framework ServiceManagement
done

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
lipo -create "$BUILD_DIR/$APP_NAME-arm64" "$BUILD_DIR/$APP_NAME-x86_64" -output "$APP_BINARY"
cp "$ROOT_DIR/Info.plist" "$APP_BUNDLE/Contents/Info.plist"

if [[ -n "${SIGN_IDENTITY:-}" ]]; then
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" \
    --entitlements "$ROOT_DIR/SpeakerBar.entitlements" "$APP_BUNDLE"
else
  codesign --force --entitlements "$ROOT_DIR/SpeakerBar.entitlements" -s - "$APP_BUNDLE"
fi

WORK_DIR="$(mktemp -d "$DIST_DIR/.dmg-work.XXXXXX")"
STAGING_DIR="$WORK_DIR/staging"
RAW_IMAGE="$WORK_DIR/source.dmg"
trap 'rm -rf "$WORK_DIR"' EXIT
mkdir -p "$STAGING_DIR"
cp -R "$APP_BUNDLE" "$STAGING_DIR/"
ln -s /Applications "$STAGING_DIR/Applications"
hdiutil makehybrid -hfs -hfs-volume-name "$APP_NAME" -o "$RAW_IMAGE" "$STAGING_DIR"
hdiutil convert -format UDZO -ov -o "$DMG_PATH" "$RAW_IMAGE"

if [[ -n "${SIGN_IDENTITY:-}" ]]; then
  codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG_PATH"
fi

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  NOTARY_RESULT="$(xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait)"
  printf '%s\n' "$NOTARY_RESULT"
  NOTARY_STATUS="$(printf '%s\n' "$NOTARY_RESULT" | sed -n 's/^[[:space:]]*status:[[:space:]]*//p' | tail -n 1)"
  if [[ "$NOTARY_STATUS" != Accepted ]]; then
    printf 'Notarization failed: %s\n' "$NOTARY_STATUS" >&2
    exit 1
  fi
  xcrun stapler staple "$DMG_PATH"
fi

printf '%s\n' "$DMG_PATH"

#!/usr/bin/env bash
# Build an UNSIGNED .ipa for sideloading with SideStore / AltStore.
#
# The output is deliberately unsigned: SideStore re-signs it on device with the
# user's own Apple ID and applies whatever entitlements that account can
# provision. A free personal team cannot provision App Groups, so the extension
# -> app handoff falls back to the photosbackup:// URL channel; see
# docs/ADR-001-auth-route.md.
set -euo pipefail

cd "$(dirname "$0")/.."
if [ -z "${DEVELOPER_DIR:-}" ]; then
  if selected="$(xcode-select -p 2>/dev/null)" && [ -d "$selected" ]; then
    DEVELOPER_DIR="$selected"
  elif [ -d /Applications/Xcode.app/Contents/Developer ]; then
    DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
  elif [ -d /Applications/Xcode-16.4.0.app/Contents/Developer ]; then
    DEVELOPER_DIR=/Applications/Xcode-16.4.0.app/Contents/Developer
  else
    echo "No Xcode developer directory found. Set DEVELOPER_DIR to Xcode.app/Contents/Developer." >&2
    exit 1
  fi
fi
export DEVELOPER_DIR

CONFIG="${1:-Release}"
BUILD_DIR="$(mktemp -d)"
OUT="$PWD/build/PhotosBackup.ipa"

command -v xcodegen >/dev/null || { echo "xcodegen not found" >&2; exit 1; }
xcodegen generate

xcodebuild -project PhotosBackup.xcodeproj -scheme PhotosBackup \
  -sdk iphoneos -configuration "$CONFIG" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  -derivedDataPath "$BUILD_DIR" build

APP="$BUILD_DIR/Build/Products/$CONFIG-iphoneos/PhotosBackup.app"
[ -d "$APP" ] || { echo "no .app at $APP" >&2; exit 1; }

STAGE="$BUILD_DIR/stage"
mkdir -p "$STAGE/Payload" "$PWD/build"
cp -R "$APP" "$STAGE/Payload/"
rm -f "$OUT"
( cd "$STAGE" && zip -qry "$OUT" Payload )
rm -rf "$BUILD_DIR"

echo "Unsigned IPA: $OUT ($(du -h "$OUT" | cut -f1))"
echo "Install by opening it in SideStore; it signs with your Apple ID on device."

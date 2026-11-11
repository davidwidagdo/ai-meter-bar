#!/usr/bin/env bash
# Usage: ./build.sh [--no-dmg] [--install]
set -euo pipefail
# System tools only, so nothing earlier on a caller's PATH can stand in for the compiler or signer.
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"
cd "$(dirname "${BASH_SOURCE[0]}")"

APP_NAME="AI Meter Bar"
BIN_NAME="AIMeterBar"
BUILD_DIR="build"
APP_DIR="${BUILD_DIR}/${APP_NAME}.app"
DMG_PATH="${BUILD_DIR}/AI-Meter-Bar.dmg"

MAKE_DMG=1
INSTALL=0
for arg in "$@"; do
  case "$arg" in
    --no-dmg) MAKE_DMG=0 ;;
    --install) INSTALL=1 ;;
    *) echo "Unknown option: $arg" >&2; exit 1 ;;
  esac
done

rm -rf "$BUILD_DIR"
mkdir -p "${APP_DIR}/Contents/MacOS" "${APP_DIR}/Contents/Resources"

# Must match LSMinimumSystemVersion in Info.plist.
DEPLOY_TARGET="arm64-apple-macosx26.0"

echo "==> Compiling Swift sources (target ${DEPLOY_TARGET})"
swiftc -O \
  -target "${DEPLOY_TARGET}" \
  -o "${APP_DIR}/Contents/MacOS/${BIN_NAME}" \
  Sources/*.swift \
  -framework Cocoa -framework Security -framework ServiceManagement -framework CoreWLAN

cp Info.plist "${APP_DIR}/Contents/Info.plist"

# Records what was built: every file in Sources is compiled, so stray or changed files are named.
if COMMIT="$(git rev-parse --short HEAD 2>/dev/null)"; then
  CHANGED="$(git status --porcelain -- . | wc -l | tr -d ' ')"
  if [ "$CHANGED" != "0" ]; then
    echo "WARNING: ${CHANGED} uncommitted or untracked file(s) under macos-app are part of this build:"
    git status --porcelain -- . | sed 's/^/    /'
    COMMIT="${COMMIT}-dirty"
  fi
  /usr/libexec/PlistBuddy -c "Add :AIMeterBarCommit string ${COMMIT}" "${APP_DIR}/Contents/Info.plist"
fi

if [ -f AppIcon.png ]; then
  echo "==> Generating app icon from AppIcon.png"
  ICONSET="${BUILD_DIR}/AppIcon.iconset"
  rm -rf "$ICONSET"; mkdir -p "$ICONSET"
  gen() { sips -z "$2" "$2" AppIcon.png --out "${ICONSET}/$1" >/dev/null; }
  gen icon_16x16.png 16;      gen icon_16x16@2x.png 32
  gen icon_32x32.png 32;      gen icon_32x32@2x.png 64
  gen icon_128x128.png 128;   gen icon_128x128@2x.png 256
  gen icon_256x256.png 256;   gen icon_256x256@2x.png 512
  gen icon_512x512.png 512;   gen icon_512x512@2x.png 1024
  iconutil -c icns "$ICONSET" -o "${APP_DIR}/Contents/Resources/AppIcon.icns"
  rm -rf "$ICONSET"
fi

# Set CODESIGN_IDENTITY to a stable certificate to stop Keychain and login item prompts on rebuilds.
echo "==> Code signing with ${CODESIGN_IDENTITY:-an ad-hoc signature}"
codesign --force --options runtime --sign "${CODESIGN_IDENTITY:--}" "${APP_DIR}"

if [ "$MAKE_DMG" = 1 ]; then
  echo "==> Building .dmg"
  STAGING="${BUILD_DIR}/dmg-staging"
  mkdir -p "$STAGING"
  cp -R "$APP_DIR" "$STAGING/"
  ln -s /Applications "$STAGING/Applications"
  hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$STAGING" \
    -ov -format UDZO \
    "$DMG_PATH" >/dev/null
  rm -rf "$STAGING"
  (cd "$BUILD_DIR" && shasum -a 256 "$(basename "$DMG_PATH")" > "$(basename "$DMG_PATH").sha256")
fi

if [ "$INSTALL" = 1 ]; then
  echo "==> Installing to /Applications"
  # Quit any running copy so the bundle is not replaced out from under it.
  pkill -x "$BIN_NAME" 2>/dev/null || true
  rm -rf "/Applications/${APP_NAME}.app"
  cp -R "$APP_DIR" "/Applications/"
fi

echo
echo "Done:"
echo "  App: ${APP_DIR}"
[ "$MAKE_DMG" = 1 ] && echo "  DMG: ${DMG_PATH}"
[ "$INSTALL" = 1 ]  && echo "  Installed: /Applications/${APP_NAME}.app"
echo
if [ "$INSTALL" = 1 ]; then
  echo "Launch it from Spotlight, or: open \"/Applications/${APP_NAME}.app\""
else
  echo "Run it with: open \"${APP_DIR}\"   (or drag it wherever you like)"
fi

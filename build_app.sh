#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="GeoViewer"
VERSION="${APP_VERSION:-0.1.0}"
CONFIGURATION="${CONFIGURATION:-release}"

BUILD_DIR=".build"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
DIST_DIR="$BUILD_DIR/dist"

export CLANG_MODULE_CACHE_PATH="$PWD/$BUILD_DIR/ModuleCache"
export SWIFTPM_HOME="$PWD/$BUILD_DIR/swiftpm"

echo "==> Building (${CONFIGURATION})"
swift build -c "$CONFIGURATION"

BIN_DIR="$(swift build -c "$CONFIGURATION" --show-bin-path)"
BIN_PATH="$BIN_DIR/$APP_NAME"
if [ ! -x "$BIN_PATH" ]; then
  echo "Build product not found: $BIN_PATH" >&2
  exit 1
fi

echo "==> Assembling app bundle"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN_PATH" "$APP_DIR/Contents/MacOS/$APP_NAME"

if [ -f "Assets/AppIcon.png" ]; then
  echo "==> Generating app icon"
  ICONSET="$BUILD_DIR/AppIcon.iconset"
  rm -rf "$ICONSET"
  mkdir -p "$ICONSET"
  for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "Assets/AppIcon.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" "Assets/AppIcon.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP_DIR/Contents/Resources/AppIcon.icns"
fi

cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh_CN</string>
    <key>CFBundleExecutable</key>
    <string>GeoViewer</string>
    <key>CFBundleIdentifier</key>
    <string>local.geoviewer.app</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>GeoViewer</string>
    <key>CFBundleDisplayName</key>
    <string>GeoViewer</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>__APP_VERSION__</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.photography</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © 2026 Gray. All rights reserved.</string>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key>
            <string>Photo</string>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>LSHandlerRank</key>
            <string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>public.jpeg</string>
                <string>public.heic</string>
                <string>public.heif</string>
                <string>public.tiff</string>
                <string>public.png</string>
                <string>public.folder</string>
                <string>com.adobe.raw-image</string>
                <string>com.canon.cr2-raw-image</string>
                <string>com.sony.arw-raw-image</string>
                <string>com.nikon.raw-image</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
PLIST

perl -0pi -e "s/__APP_VERSION__/$VERSION/g" "$APP_DIR/Contents/Info.plist"

echo "==> Ad-hoc signing"
codesign --force --sign - "$APP_DIR" >/dev/null 2>&1 || echo "(ad-hoc signing failed, local run still works)"

if [ "${MAKE_DMG:-0}" = "1" ]; then
  echo "==> Creating DMG"
  mkdir -p "$DIST_DIR"
  STAGING="$BUILD_DIR/dmg"
  rm -rf "$STAGING"
  mkdir -p "$STAGING"
  cp -R "$APP_DIR" "$STAGING/"
  ln -s /Applications "$STAGING/Applications"
  DMG_PATH="$DIST_DIR/$APP_NAME-$VERSION.dmg"
  rm -f "$DMG_PATH"
  hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING" -ov -format UDZO "$DMG_PATH" >/dev/null
  echo "DMG: $DMG_PATH"
fi

echo "Done: $APP_DIR"

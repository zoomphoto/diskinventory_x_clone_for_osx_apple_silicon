#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

APP_NAME="Disk Inventory"
EXEC_NAME="DiskInventoryApp"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

echo "==> Compiling native Apple Silicon (arm64) release binary..."
swift build -c release --arch arm64

BIN_PATH="$(swift build -c release --arch arm64 --show-bin-path)/$EXEC_NAME"
if [[ ! -f "$BIN_PATH" ]]; then
    echo "Error: Expected binary not found at $BIN_PATH" >&2
    exit 1
fi

echo "==> Assembling $APP_BUNDLE..."
rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$BIN_PATH" "$MACOS_DIR/$EXEC_NAME"
chmod +x "$MACOS_DIR/$EXEC_NAME"

ICONSET_TMP="$(mktemp -d)/AppIcon.iconset"
echo "==> Generating Retina Cushion Treemap app icon..."
swift "$ROOT_DIR/scripts/generate_icon.swift" "$ICONSET_TMP"
iconutil -c icns "$ICONSET_TMP" -o "$RESOURCES_DIR/AppIcon.icns"
rm -rf "$(dirname "$ICONSET_TMP")"

cat > "$CONTENTS_DIR/Info.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleDisplayName</key>
    <string>Disk Inventory</string>
    <key>CFBundleExecutable</key>
    <string>DiskInventoryApp</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.local.diskinventory</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Disk Inventory</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>2.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSDesktopFolderUsageDescription</key>
    <string>Disk Inventory needs access to analyze file sizes in your Desktop folder.</string>
    <key>NSDocumentsFolderUsageDescription</key>
    <string>Disk Inventory needs access to analyze file sizes in your Documents folder.</string>
    <key>NSDownloadsFolderUsageDescription</key>
    <string>Disk Inventory needs access to analyze file sizes in your Downloads folder.</string>
    <key>NSRemovableVolumesUsageDescription</key>
    <string>Disk Inventory needs access to analyze storage usage on external volumes.</string>
    <key>NSNetworkVolumesUsageDescription</key>
    <string>Disk Inventory needs access to analyze storage usage on network volumes.</string>
</dict>
</plist>
EOF

echo "==> Signing $APP_NAME.app (ad-hoc arm64 signature)..."
codesign --force --deep --sign - "$APP_BUNDLE"

echo ""
echo "Built native Apple Silicon app:"
echo "  $APP_BUNDLE"
echo ""
echo "Launch with:"
echo "  open \"$APP_BUNDLE\""
echo "Or copy to /Applications:"
echo "  cp -R \"$APP_BUNDLE\" /Applications/"


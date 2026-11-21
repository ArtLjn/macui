#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

configuration=release
if [ "$#" -gt 0 ]; then
    configuration="$1"
fi
swift build --configuration "$configuration"
bin_dir="$(swift build --configuration "$configuration" --show-bin-path)"
depth_model="$(bash Scripts/prepare-depth-model.sh)"
bundle="$PWD/dist/macui.app"
motion_bundle="$bundle/Contents/Helpers/WallpaperMotion.app"
iconset="$PWD/.build/AppIcon.iconset"
master_icon="$PWD/Bundle/AppIcon.png"

mkdir -p "$iconset"
for size in 16 32 128 256 512; do
    doubled=$((size * 2))
    sips -z "$size" "$size" "$master_icon" --out "$iconset/icon_${size}x${size}.png" >/dev/null
    sips -z "$doubled" "$doubled" "$master_icon" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$PWD/.build/AppIcon.icns"

mkdir -p "$bundle/Contents/MacOS"
mkdir -p "$bundle/Contents/Resources"
install -m 755 "$bin_dir/WallpaperWall" "$bundle/Contents/MacOS/WallpaperWall"
install -m 644 Bundle/Info.plist "$bundle/Contents/Info.plist"
install -m 644 .build/AppIcon.icns "$bundle/Contents/Resources/AppIcon.icns"
ditto "$depth_model" "$bundle/Contents/Resources/$(basename "$depth_model")"
install -m 644 Bundle/Depth-Anything-V2-LICENSE Bundle/DepthModel-NOTICE.md "$bundle/Contents/Resources"
mkdir -p "$motion_bundle/Contents/MacOS"
install -m 755 "$bin_dir/WallpaperWall" "$motion_bundle/Contents/MacOS/WallpaperWall"
install -m 644 Bundle/MotionInfo.plist "$motion_bundle/Contents/Info.plist"
for key in CFBundleShortVersionString CFBundleVersion; do
    plutil -replace "$key" -string "$(plutil -extract "$key" raw Bundle/Info.plist)" "$motion_bundle/Contents/Info.plist"
done
plutil -lint "$bundle/Contents/Info.plist"
plutil -lint "$motion_bundle/Contents/Info.plist"
codesign --force --sign - "$motion_bundle"
codesign --force --sign - "$bundle"
codesign --verify --deep --strict "$bundle"
printf '%s\n' "$bundle"

#!/bin/zsh
# Builds Tackroom.app into ./build (locally signed; no Apple account needed).
set -e
cd "$(dirname "$0")/.."
swift build -c release --product TackroomApp
swift build -c release --product tackroom
BIN=$(swift build -c release --show-bin-path)
APP=build/Tackroom.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/TackroomApp" "$APP/Contents/MacOS/Tackroom"
# The agent command line and its how-to skill ship inside the app.
cp "$BIN/tackroom" "$APP/Contents/Resources/tackroom"
cp -R skills/tackroom "$APP/Contents/Resources/tackroom-skill"
# Text in 繁體中文 (the source), 简体中文 and English.
cp -R Localization/*.lproj "$APP/Contents/Resources/"
VERSION=$(git describe --tags --always 2>/dev/null || echo dev)
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>local.tackroom.app</string>
  <key>CFBundleName</key><string>Tackroom</string>
  <key>CFBundleDisplayName</key><string>Tackroom</string>
  <key>CFBundleExecutable</key><string>Tackroom</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleDevelopmentRegion</key><string>zh-Hant</string>
  <key>CFBundleLocalizations</key><array><string>zh-Hant</string><string>zh-Hans</string><string>en</string></array>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
EOF
codesign --force --sign - --options runtime "$APP/Contents/Resources/tackroom"
codesign --force --sign - --options runtime "$APP"
echo "built $APP"

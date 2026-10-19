#!/bin/zsh
# Builds build/Flick.app from Player/*.swift
set -e
cd "${0:A:h}"
APP=build/Flick.app
rm -rf $APP; mkdir -p $APP/Contents/{MacOS,Resources}
swiftc -O -swift-version 5 -target arm64-apple-macos14 -o $APP/Contents/MacOS/Flick Player/*.swift
[[ -f Player/AppIcon.icns ]] && cp Player/AppIcon.icns $APP/Contents/Resources/
cat > $APP/Contents/Info.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Flick</string>
<key>CFBundleIdentifier</key><string>app.flick.player</string>
<key>CFBundleExecutable</key><string>Flick</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.2</string>
<key>CFBundleVersion</key><string>2</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>CFBundleDocumentTypes</key><array><dict>
  <key>CFBundleTypeName</key><string>Video</string>
  <key>CFBundleTypeRole</key><string>Viewer</string>
  <key>LSHandlerRank</key><string>Alternate</string>
  <key>LSItemContentTypes</key><array><string>public.movie</string><string>public.video</string><string>org.matroska.mkv</string><string>org.webmproject.webm</string></array>
</dict></array>
</dict></plist>
PLIST
codesign -s - --force $APP
echo built $APP

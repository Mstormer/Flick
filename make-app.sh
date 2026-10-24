#!/bin/zsh
# Builds build/Flick.app from Player/*.swift
set -e
cd "${0:A:h}"
APP=build/Flick.app
FF=Vendor/ffmpeg
[[ -f $FF/lib/libavcodec.dylib ]] || Tools/build-ffmpeg.sh
rm -rf $APP; mkdir -p $APP/Contents/{MacOS,Resources,Frameworks}
swiftc -O -swift-version 5 -target arm64-apple-macos14 -o $APP/Contents/MacOS/Flick Player/*.swift \
  -I Player/CFFmpeg -Xcc -I$FF/include -L $FF/lib -Xlinker -rpath -Xlinker @executable_path/../Frameworks
# the LGPL FFmpeg libraries, as separate dylibs (users may replace them with their own build)
for l in libavformat.63 libavcodec.63 libavutil.61; do
  cp -L $FF/lib/$l.dylib $APP/Contents/Frameworks/
  strip -x $APP/Contents/Frameworks/$l.dylib
  codesign -s - --force $APP/Contents/Frameworks/$l.dylib
done
cp Player/Licenses.txt $APP/Contents/Resources/
[[ -f Player/AppIcon.icns ]] && cp Player/AppIcon.icns $APP/Contents/Resources/
cat > $APP/Contents/Info.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Flick</string>
<key>CFBundleIdentifier</key><string>app.flick.player</string>
<key>CFBundleExecutable</key><string>Flick</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.2.2</string>
<key>CFBundleVersion</key><string>4</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>CFBundleDocumentTypes</key><array><dict>
  <key>CFBundleTypeName</key><string>Video</string>
  <key>CFBundleTypeRole</key><string>Viewer</string>
  <key>LSHandlerRank</key><string>Alternate</string>
  <key>LSItemContentTypes</key><array><string>public.movie</string><string>public.video</string><string>org.matroska.mkv</string><string>org.webmproject.webm</string><string>com.microsoft.windows-media-wmv</string><string>com.microsoft.advanced-systems-format</string></array>
</dict></array>
</dict></plist>
PLIST
codesign -s - --force $APP
echo built $APP

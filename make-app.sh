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
for l in libavformat.63 libavcodec.63 libavutil.61 libswscale.10 libswresample.7; do
  cp -L $FF/lib/$l.dylib $APP/Contents/Frameworks/
  strip -x $APP/Contents/Frameworks/$l.dylib
  codesign -s - --force $APP/Contents/Frameworks/$l.dylib
done
# the license notice carries the exact FFmpeg build configuration (with local paths made relative)
# (the tree of the version build-ffmpeg.sh builds: an older extracted tree would add its own, stale line)
VER=$(sed -n 's/^VER=//p' Tools/build-ffmpeg.sh)
CONF=$(sed -n 's/^#define FFMPEG_CONFIGURATION "\(.*\)"$/\1/p' Vendor/src/ffmpeg-$VER/config.h | sed "s#$PWD/##g")
[[ -n $CONF ]] || { echo "no FFmpeg build configuration found" >&2; exit 1; }
CONF="$CONF" awk '{ gsub("@FFMPEG_CONFIGURATION@", ENVIRON["CONF"]); print }' Player/Licenses.txt > $APP/Contents/Resources/Licenses.txt
{ printf '\n------------------------------------------------------------------------------\nFlick: GNU General Public License version 3\n\n'; cat LICENSE; } >> $APP/Contents/Resources/Licenses.txt
cp Player/Credits.html $APP/Contents/Resources/                 # shown in the About box
[[ -f Player/AppIcon.icns ]] && cp Player/AppIcon.icns $APP/Contents/Resources/
cat > $APP/Contents/Info.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Flick</string>
<key>CFBundleIdentifier</key><string>app.flick.player</string>
<key>CFBundleExecutable</key><string>Flick</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.2.8</string>
<key>CFBundleVersion</key><string>10</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>CFBundleDocumentTypes</key><array><dict>
  <key>CFBundleTypeName</key><string>Video</string>
  <key>CFBundleTypeRole</key><string>Viewer</string>
  <key>LSHandlerRank</key><string>Alternate</string>
  <key>LSItemContentTypes</key><array><string>public.movie</string><string>public.video</string><string>org.matroska.mkv</string><string>org.webmproject.webm</string><string>com.microsoft.advanced-systems-format</string><string>com.microsoft.windows-media-wmv</string><string>app.flick.divx</string><string>app.flick.vob</string><string>app.flick.mpeg-video</string><string>app.flick.transport-stream</string><string>org.xiph.ogv</string><string>com.adobe.flash.video</string><string>com.real.realmedia</string><string>org.smpte.mxf</string><string>app.flick.nut</string><string>app.flick.ivf</string><string>app.flick.y4m</string><string>app.flick.wtv</string><string>app.flick.h264</string><string>app.flick.hevc</string><string>app.flick.mjpeg</string></array>
</dict><dict>
  <key>CFBundleTypeName</key><string>Audio</string>
  <key>CFBundleTypeRole</key><string>Viewer</string>
  <key>LSHandlerRank</key><string>Alternate</string>
  <key>LSItemContentTypes</key><array><string>public.audio</string><string>org.matroska.mka</string><string>com.microsoft.windows-media-wma</string><string>org.xiph.ogg-audio</string><string>org.xiph.opus</string><string>org.xiph.flac</string><string>com.real.realaudio</string><string>app.flick.ape</string><string>app.flick.wavpack</string><string>app.flick.tta</string><string>app.flick.musepack</string><string>app.flick.tak</string><string>app.flick.dts</string><string>app.flick.truehd</string><string>app.flick.dsf</string><string>app.flick.wave64</string><string>app.flick.voc</string><string>app.flick.shorten</string><string>app.flick.xwma</string></array>
</dict></array>
<!-- formats macOS has no type for (another player may declare them too; either way they open here) -->
<key>UTImportedTypeDeclarations</key><array>
  <dict><key>UTTypeIdentifier</key><string>org.matroska.mkv</string><key>UTTypeDescription</key><string>Matroska video</string>
    <key>UTTypeConformsTo</key><array><string>public.movie</string></array>
    <key>UTTypeTagSpecification</key><dict><key>public.filename-extension</key><array><string>mkv</string><string>mk3d</string></array></dict></dict>
  <dict><key>UTTypeIdentifier</key><string>org.matroska.mka</string><key>UTTypeDescription</key><string>Matroska audio</string>
    <key>UTTypeConformsTo</key><array><string>public.audio</string></array>
    <key>UTTypeTagSpecification</key><dict><key>public.filename-extension</key><array><string>mka</string></array></dict></dict>
  <dict><key>UTTypeIdentifier</key><string>org.webmproject.webm</string><key>UTTypeDescription</key><string>WebM video</string>
    <key>UTTypeConformsTo</key><array><string>public.movie</string></array>
    <key>UTTypeTagSpecification</key><dict><key>public.filename-extension</key><array><string>webm</string></array></dict></dict>
  <dict><key>UTTypeIdentifier</key><string>com.microsoft.advanced-systems-format</string><key>UTTypeDescription</key><string>Windows Media file</string>
    <key>UTTypeConformsTo</key><array><string>public.movie</string></array>
    <key>UTTypeTagSpecification</key><dict><key>public.filename-extension</key><array><string>asf</string></array></dict></dict>
  <dict><key>UTTypeIdentifier</key><string>com.microsoft.windows-media-wmv</string><key>UTTypeDescription</key><string>Windows Media video</string>
    <key>UTTypeConformsTo</key><array><string>public.movie</string></array>
    <key>UTTypeTagSpecification</key><dict><key>public.filename-extension</key><array><string>wmv</string></array></dict></dict>
  <dict><key>UTTypeIdentifier</key><string>com.microsoft.windows-media-wma</string><key>UTTypeDescription</key><string>Windows Media audio</string>
    <key>UTTypeConformsTo</key><array><string>public.audio</string></array>
    <key>UTTypeTagSpecification</key><dict><key>public.filename-extension</key><array><string>wma</string></array></dict></dict>
  <dict><key>UTTypeIdentifier</key><string>app.flick.divx</string><key>UTTypeDescription</key><string>DivX video</string>
    <key>UTTypeConformsTo</key><array><string>public.movie</string></array>
    <key>UTTypeTagSpecification</key><dict><key>public.filename-extension</key><array><string>divx</string><string>xvid</string></array></dict></dict>
  <dict><key>UTTypeIdentifier</key><string>app.flick.vob</string><key>UTTypeDescription</key><string>DVD video object</string>
    <key>UTTypeConformsTo</key><array><string>public.movie</string></array>
    <key>UTTypeTagSpecification</key><dict><key>public.filename-extension</key><array><string>vob</string></array></dict></dict>
  <dict><key>UTTypeIdentifier</key><string>app.flick.mpeg-video</string><key>UTTypeDescription</key><string>MPEG video stream</string>
    <key>UTTypeConformsTo</key><array><string>public.movie</string></array>
    <key>UTTypeTagSpecification</key><dict><key>public.filename-extension</key><array><string>m1v</string><string>mpv</string></array></dict></dict>
  <dict><key>UTTypeIdentifier</key><string>app.flick.transport-stream</string><key>UTTypeDescription</key><string>MPEG transport stream</string>
    <key>UTTypeConformsTo</key><array><string>public.movie</string></array>
    <key>UTTypeTagSpecification</key><dict><key>public.filename-extension</key><array><string>m2t</string><string>tp</string><string>trp</string></array></dict></dict>
  <dict><key>UTTypeIdentifier</key><string>org.xiph.ogv</string><key>UTTypeDescription</key><string>Ogg video</string>
    <key>UTTypeConformsTo</key><array><string>public.movie</string></array>
    <key>UTTypeTagSpecification</key><dict><key>public.filename-extension</key><array><string>ogv</string><string>ogm</string></array></dict></dict>
  <dict><key>UTTypeIdentifier</key><string>org.xiph.ogg-audio</string><key>UTTypeDescription</key><string>Ogg audio</string>
    <key>UTTypeConformsTo</key><array><string>public.audio</string></array>
    <key>UTTypeTagSpecification</key><dict><key>public.filename-extension</key><array><string>ogg</string><string>oga</string><string>spx</string></array></dict></dict>
  <dict><key>UTTypeIdentifier</key><string>org.xiph.opus</string><key>UTTypeDescription</key><string>Opus audio</string>
    <key>UTTypeConformsTo</key><array><string>public.audio</string></array>
    <key>UTTypeTagSpecification</key><dict><key>public.filename-extension</key><array><string>opus</string></array></dict></dict>
  <dict><key>UTTypeIdentifier</key><string>org.xiph.flac</string><key>UTTypeDescription</key><string>FLAC audio</string>
    <key>UTTypeConformsTo</key><array><string>public.audio</string></array>
    <key>UTTypeTagSpecification</key><dict><key>public.filename-extension</key><array><string>flac</string></array></dict></dict>
  <dict><key>UTTypeIdentifier</key><string>com.adobe.flash.video</string><key>UTTypeDescription</key><string>Flash video</string>
    <key>UTTypeConformsTo</key><array><string>public.movie</string></array>
    <key>UTTypeTagSpecification</key><dict><key>public.filename-extension</key><array><string>flv</string><string>f4v</string></array></dict></dict>
  <dict><key>UTTypeIdentifier</key><string>com.real.realmedia</string><key>UTTypeDescription</key><string>RealMedia</string>
    <key>UTTypeConformsTo</key><array><string>public.movie</string></array>
    <key>UTTypeTagSpecification</key><dict><key>public.filename-extension</key><array><string>rm</string><string>rmvb</string></array></dict></dict>
  <dict><key>UTTypeIdentifier</key><string>com.real.realaudio</string><key>UTTypeDescription</key><string>RealAudio</string>
    <key>UTTypeConformsTo</key><array><string>public.audio</string></array>
    <key>UTTypeTagSpecification</key><dict><key>public.filename-extension</key><array><string>ra</string></array></dict></dict>
  <dict><key>UTTypeIdentifier</key><string>org.smpte.mxf</string><key>UTTypeDescription</key><string>MXF video</string>
    <key>UTTypeConformsTo</key><array><string>public.movie</string></array>
    <key>UTTypeTagSpecification</key><dict><key>public.filename-extension</key><array><string>mxf</string></array></dict></dict>
  <dict><key>UTTypeIdentifier</key><string>app.flick.nut</string><key>UTTypeDescription</key><string>NUT video</string>
    <key>UTTypeConformsTo</key><array><string>public.movie</string></array>
    <key>UTTypeTagSpecification</key><dict><key>public.filename-extension</key><array><string>nut</string></array></dict></dict>
  <dict><key>UTTypeIdentifier</key><string>app.flick.ivf</string><key>UTTypeDescription</key><string>IVF video</string>
    <key>UTTypeConformsTo</key><array><string>public.movie</string></array>
    <key>UTTypeTagSpecification</key><dict><key>public.filename-extension</key><array><string>ivf</string></array></dict></dict>
  <dict><key>UTTypeIdentifier</key><string>app.flick.y4m</string><key>UTTypeDescription</key><string>YUV4MPEG video</string>
    <key>UTTypeConformsTo</key><array><string>public.movie</string></array>
    <key>UTTypeTagSpecification</key><dict><key>public.filename-extension</key><array><string>y4m</string></array></dict></dict>
  <dict><key>UTTypeIdentifier</key><string>app.flick.wtv</string><key>UTTypeDescription</key><string>Windows recorded TV</string>
    <key>UTTypeConformsTo</key><array><string>public.movie</string></array>
    <key>UTTypeTagSpecification</key><dict><key>public.filename-extension</key><array><string>wtv</string></array></dict></dict>
  <dict><key>UTTypeIdentifier</key><string>app.flick.h264</string><key>UTTypeDescription</key><string>H.264 video stream</string>
    <key>UTTypeConformsTo</key><array><string>public.movie</string></array>
    <key>UTTypeTagSpecification</key><dict><key>public.filename-extension</key><array><string>h264</string><string>264</string></array></dict></dict>
  <dict><key>UTTypeIdentifier</key><string>app.flick.hevc</string><key>UTTypeDescription</key><string>HEVC video stream</string>
    <key>UTTypeConformsTo</key><array><string>public.movie</string></array>
    <key>UTTypeTagSpecification</key><dict><key>public.filename-extension</key><array><string>h265</string><string>265</string><string>hevc</string></array></dict></dict>
  <dict><key>UTTypeIdentifier</key><string>app.flick.mjpeg</string><key>UTTypeDescription</key><string>Motion JPEG video</string>
    <key>UTTypeConformsTo</key><array><string>public.movie</string></array>
    <key>UTTypeTagSpecification</key><dict><key>public.filename-extension</key><array><string>mjpg</string><string>mjpeg</string></array></dict></dict>
  <dict><key>UTTypeIdentifier</key><string>app.flick.ape</string><key>UTTypeDescription</key><string>Monkey's Audio</string>
    <key>UTTypeConformsTo</key><array><string>public.audio</string></array>
    <key>UTTypeTagSpecification</key><dict><key>public.filename-extension</key><array><string>ape</string></array></dict></dict>
  <dict><key>UTTypeIdentifier</key><string>app.flick.wavpack</string><key>UTTypeDescription</key><string>WavPack audio</string>
    <key>UTTypeConformsTo</key><array><string>public.audio</string></array>
    <key>UTTypeTagSpecification</key><dict><key>public.filename-extension</key><array><string>wv</string></array></dict></dict>
  <dict><key>UTTypeIdentifier</key><string>app.flick.tta</string><key>UTTypeDescription</key><string>True Audio</string>
    <key>UTTypeConformsTo</key><array><string>public.audio</string></array>
    <key>UTTypeTagSpecification</key><dict><key>public.filename-extension</key><array><string>tta</string></array></dict></dict>
  <dict><key>UTTypeIdentifier</key><string>app.flick.musepack</string><key>UTTypeDescription</key><string>Musepack audio</string>
    <key>UTTypeConformsTo</key><array><string>public.audio</string></array>
    <key>UTTypeTagSpecification</key><dict><key>public.filename-extension</key><array><string>mpc</string></array></dict></dict>
  <dict><key>UTTypeIdentifier</key><string>app.flick.tak</string><key>UTTypeDescription</key><string>TAK audio</string>
    <key>UTTypeConformsTo</key><array><string>public.audio</string></array>
    <key>UTTypeTagSpecification</key><dict><key>public.filename-extension</key><array><string>tak</string></array></dict></dict>
  <dict><key>UTTypeIdentifier</key><string>app.flick.dts</string><key>UTTypeDescription</key><string>DTS audio</string>
    <key>UTTypeConformsTo</key><array><string>public.audio</string></array>
    <key>UTTypeTagSpecification</key><dict><key>public.filename-extension</key><array><string>dts</string><string>dtshd</string></array></dict></dict>
  <dict><key>UTTypeIdentifier</key><string>app.flick.truehd</string><key>UTTypeDescription</key><string>Dolby TrueHD audio</string>
    <key>UTTypeConformsTo</key><array><string>public.audio</string></array>
    <key>UTTypeTagSpecification</key><dict><key>public.filename-extension</key><array><string>thd</string><string>mlp</string></array></dict></dict>
  <dict><key>UTTypeIdentifier</key><string>app.flick.dsf</string><key>UTTypeDescription</key><string>DSD audio</string>
    <key>UTTypeConformsTo</key><array><string>public.audio</string></array>
    <key>UTTypeTagSpecification</key><dict><key>public.filename-extension</key><array><string>dsf</string></array></dict></dict>
  <dict><key>UTTypeIdentifier</key><string>app.flick.wave64</string><key>UTTypeDescription</key><string>Wave64 audio</string>
    <key>UTTypeConformsTo</key><array><string>public.audio</string></array>
    <key>UTTypeTagSpecification</key><dict><key>public.filename-extension</key><array><string>w64</string></array></dict></dict>
  <dict><key>UTTypeIdentifier</key><string>app.flick.voc</string><key>UTTypeDescription</key><string>Creative Voice audio</string>
    <key>UTTypeConformsTo</key><array><string>public.audio</string></array>
    <key>UTTypeTagSpecification</key><dict><key>public.filename-extension</key><array><string>voc</string></array></dict></dict>
  <dict><key>UTTypeIdentifier</key><string>app.flick.shorten</string><key>UTTypeDescription</key><string>Shorten audio</string>
    <key>UTTypeConformsTo</key><array><string>public.audio</string></array>
    <key>UTTypeTagSpecification</key><dict><key>public.filename-extension</key><array><string>shn</string></array></dict></dict>
  <dict><key>UTTypeIdentifier</key><string>app.flick.xwma</string><key>UTTypeDescription</key><string>XWMA audio</string>
    <key>UTTypeConformsTo</key><array><string>public.audio</string></array>
    <key>UTTypeTagSpecification</key><dict><key>public.filename-extension</key><array><string>xwma</string></array></dict></dict>
</array>
</dict></plist>
PLIST
codesign -s - --force $APP
echo built $APP

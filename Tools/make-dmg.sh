#!/bin/zsh
# Packs build/Flick.app into build/Flick-<version>.dmg and build/Flick-<version>.zip (the zip holds the dmg: what a release attaches)
set -e
cd "${0:A:h}/.."
APP=build/Flick.app
VER=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' $APP/Contents/Info.plist)
STAGE=$(mktemp -d build/dmg.XXXXXX)
ditto $APP $STAGE/Flick.app; ln -s /Applications $STAGE/Applications
rm -f build/Flick-$VER.dmg build/Flick-$VER.zip
hdiutil create -quiet -volname Flick -srcfolder $STAGE -fs HFS+ -format UDZO build/Flick-$VER.dmg
/usr/bin/trash $STAGE
[[ -n $FLICK_SIGN_IDENTITY ]] && codesign --force --timestamp -s "$FLICK_SIGN_IDENTITY" build/Flick-$VER.dmg      # a signed image is what notarization staples
(cd build && zip -q -X Flick-$VER.zip Flick-$VER.dmg)
echo "build/Flick-$VER.dmg, build/Flick-$VER.zip"

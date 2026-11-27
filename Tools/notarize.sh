#!/bin/zsh
# Notarizes build/Flick.app (built with FLICK_SIGN_IDENTITY set) and makes the release files.
# usage: FLICK_SIGN_IDENTITY="Developer ID Application: …" FLICK_NOTARY_PROFILE=flick-notary Tools/notarize.sh
# Steps: check the signature as the notary service will, notarize and staple the app, put the stapled app in a disk image,
# sign, notarize and staple that, check both as Gatekeeper does, zip the dmg (what a release attaches) and write its SHA-256.
set -eu
cd "${0:A:h}/.."
: ${FLICK_SIGN_IDENTITY:?set FLICK_SIGN_IDENTITY to the Developer ID Application identity} ${FLICK_NOTARY_PROFILE:?set FLICK_NOTARY_PROFILE to the notarytool keychain profile}
APP=build/Flick.app
VER=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' $APP/Contents/Info.plist)
DMG=build/Flick-$VER.dmg ZIP=build/Flick-$VER.zip
echo "== checking the signature"
codesign --verify --deep --strict --verbose=2 $APP
codesign -dvv $APP 2>&1 | grep -q "flags=0x10000(runtime)" || { echo "FAIL: hardened runtime is off (build with FLICK_SIGN_IDENTITY set)" >&2; exit 1; }
codesign -d --entitlements - $APP 2>/dev/null | grep -q get-task-allow && { echo "FAIL: get-task-allow (debug entitlement) is present" >&2; exit 1; }
for f in $APP/Contents/Frameworks/*.dylib; do codesign -dvv $f 2>&1 | grep -q "Timestamp=" || { echo "FAIL: no secure timestamp on $f" >&2; exit 1; }; done
echo "== notarizing the app"
W=$(mktemp -d build/notary.XXXXXX)
ditto -c -k --keepParent $APP $W/Flick-app.zip
xcrun notarytool submit $W/Flick-app.zip --keychain-profile $FLICK_NOTARY_PROFILE --wait --output-format json > build/notary-app.json
grep -q '"status" *: *"Accepted"' build/notary-app.json || { echo "FAIL: app not accepted, see build/notary-app.json (notarytool log <id> --keychain-profile …)" >&2; cat build/notary-app.json >&2; exit 1; }
xcrun stapler staple $APP
echo "== disk image"
Tools/make-dmg.sh
echo "== notarizing the disk image"
xcrun notarytool submit $DMG --keychain-profile $FLICK_NOTARY_PROFILE --wait --output-format json > build/notary-dmg.json
grep -q '"status" *: *"Accepted"' build/notary-dmg.json || { echo "FAIL: dmg not accepted, see build/notary-dmg.json" >&2; cat build/notary-dmg.json >&2; exit 1; }
xcrun stapler staple $DMG
/usr/bin/trash $W
echo "== Gatekeeper checks"
xcrun stapler validate $APP; xcrun stapler validate $DMG
spctl -a -t exec -vv $APP
spctl -a -t open --context context:primary-signature -vv $DMG
rm -f $ZIP; (cd build && zip -q -X Flick-$VER.zip Flick-$VER.dmg)
(cd build && shasum -a 256 Flick-$VER.zip | tee Flick-$VER.zip.sha256)
echo "notarized: $ZIP (attach it and its .sha256 to the release)"

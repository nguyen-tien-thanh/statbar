#!/bin/bash
# Builds StatBar.app and StatBar.dmg into ./build
set -euo pipefail
cd "$(dirname "$0")"

APP=StatBar
BUILD=build
OBJ=$BUILD/obj
BUNDLE=$BUILD/$APP.app
ARCH=${ARCH:-universal}           # ARCH=arm64 ./build.sh for Apple Silicon only
MIN=13.0

rm -rf "$BUILD"; mkdir -p "$OBJ" "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"

if [ "$ARCH" = universal ]; then ARCHS="arm64 x86_64"; else ARCHS="$ARCH"; fi

for A in $ARCHS; do
  echo "▸ Compiling ($A)"
  clang -O2 -arch $A -mmacosx-version-min=$MIN -c Bridge/smc.c -o $OBJ/smc-$A.o
  clang -O2 -arch $A -mmacosx-version-min=$MIN Helper/helper.c $OBJ/smc-$A.o -framework IOKit -framework CoreFoundation -o $OBJ/statbar-helper-$A
  swiftc -O -whole-module-optimization -swift-version 5 \
    -target $A-apple-macos$MIN \
    -import-objc-header Bridge/Bridge.h \
    Sources/*.swift $OBJ/smc-$A.o \
    -framework IOKit -framework CoreWLAN -framework SystemConfiguration \
    -framework CoreAudio -framework CoreMediaIO -framework ServiceManagement -framework LocalAuthentication \
    -o $OBJ/$APP-$A
done

lipo -create $(for A in $ARCHS; do echo $OBJ/$APP-$A; done) -output "$BUNDLE/Contents/MacOS/$APP"
lipo -create $(for A in $ARCHS; do echo $OBJ/statbar-helper-$A; done) -output "$BUNDLE/Contents/MacOS/statbar-helper"
strip -x "$BUNDLE/Contents/MacOS/$APP" "$BUNDLE/Contents/MacOS/statbar-helper"

cp Resources/Info.plist "$BUNDLE/Contents/Info.plist"

echo "▸ Icon"
swift scripts/make_icon.swift $OBJ/AppIcon.iconset
iconutil -c icns $OBJ/AppIcon.iconset -o "$BUNDLE/Contents/Resources/AppIcon.icns"

echo "▸ Signing (ad-hoc)"
codesign --force --deep --sign - "$BUNDLE"

echo "▸ DMG"
GUIDE="Hướng dẫn cài đặt.html"
STAGE=$OBJ/dmg; mkdir -p "$STAGE/.background"
cp -R "$BUNDLE" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp Resources/Install.html "$STAGE/$GUIDE"
SetFile -a E "$STAGE/$GUIDE" 2>/dev/null || true          # hide ".html" in Finder
swift scripts/make_dmg_background.swift $OBJ/bg
tiffutil -cathidpicheck $OBJ/bg/background.png $OBJ/bg/background@2x.png -out "$STAGE/.background/background.tiff" 2>/dev/null

# Writable image -> lay out the Finder window -> compress.
RW=$OBJ/rw.dmg
hdiutil create -volname "$APP" -srcfolder "$STAGE" -ov -format UDRW -fs HFS+ -quiet "$RW"
MNT=$(hdiutil attach "$RW" -readwrite -noverify -noautoopen | awk -F'\t' '/\/Volumes\//{print $NF}')
# Window 640x440 content (+28 title bar); icon positions match scripts/make_dmg_background.swift
if ! osascript - "$MNT" "$APP.app" "$GUIDE" <<'OSA'
on run argv
  set mnt to item 1 of argv
  tell application "Finder"
    set d to (POSIX file mnt as alias)
    open d
    set w to container window of d
    set current view of w to icon view
    set toolbar visible of w to false
    set statusbar visible of w to false
    set bounds of w to {200, 120, 840, 588}
    set o to icon view options of w
    set arrangement of o to not arranged
    set icon size of o to 96
    set text size of o to 13
    set background picture of o to (POSIX file (mnt & "/.background/background.tiff") as alias)
    set position of item (item 2 of argv) of d to {160, 175}
    set position of item "Applications" of d to {480, 175}
    set position of item (item 3 of argv) of d to {500, 345}
    update d without registering applications
    delay 1
    close w
  end tell
end run
OSA
then echo "  ! Finder layout skipped (allow Terminal to control Finder in Privacy & Security > Automation)"; fi
sync; sleep 1
rm -rf "$MNT/.fseventsd"
hdiutil detach "$MNT" -quiet || hdiutil detach "$MNT" -force -quiet
hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -ov -quiet -o "$BUILD/$APP.dmg"
rm -f "$RW"

echo "✓ $(du -sh "$BUNDLE" | cut -f1)  $BUNDLE"
echo "✓ $(du -sh "$BUILD/$APP.dmg" | cut -f1)  $BUILD/$APP.dmg"

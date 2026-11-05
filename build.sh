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
  clang -O2 -arch $A -mmacosx-version-min=$MIN Helper/fan.c $OBJ/smc-$A.o -framework IOKit -o $OBJ/statbar-fan-$A
  swiftc -O -whole-module-optimization -swift-version 5 \
    -target $A-apple-macos$MIN \
    -import-objc-header Bridge/Bridge.h \
    Sources/*.swift $OBJ/smc-$A.o \
    -framework IOKit -framework CoreWLAN -framework SystemConfiguration \
    -framework CoreAudio -framework CoreMediaIO -framework ServiceManagement \
    -o $OBJ/$APP-$A
done

lipo -create $(for A in $ARCHS; do echo $OBJ/$APP-$A; done) -output "$BUNDLE/Contents/MacOS/$APP"
lipo -create $(for A in $ARCHS; do echo $OBJ/statbar-fan-$A; done) -output "$BUNDLE/Contents/MacOS/statbar-fan"
strip -x "$BUNDLE/Contents/MacOS/$APP" "$BUNDLE/Contents/MacOS/statbar-fan"

cp Resources/Info.plist "$BUNDLE/Contents/Info.plist"

echo "▸ Icon"
swift scripts/make_icon.swift $OBJ/AppIcon.iconset
iconutil -c icns $OBJ/AppIcon.iconset -o "$BUNDLE/Contents/Resources/AppIcon.icns"

echo "▸ Signing (ad-hoc)"
codesign --force --deep --sign - "$BUNDLE"

echo "▸ DMG"
STAGE=$OBJ/dmg; mkdir -p "$STAGE"
cp -R "$BUNDLE" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp Resources/INSTALL.txt "$STAGE/Cài đặt - Install.txt"
hdiutil create -volname "$APP" -srcfolder "$STAGE" -ov -format UDZO -quiet "$BUILD/$APP.dmg"

echo "✓ $(du -sh "$BUNDLE" | cut -f1)  $BUNDLE"
echo "✓ $(du -sh "$BUILD/$APP.dmg" | cut -f1)  $BUILD/$APP.dmg"

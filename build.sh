#!/bin/sh
# Build OX Link: a universal (Apple silicon + Intel) app, signed, then a zip and a disk image
# with SHA-256 checksums in dist/.
#
#   ./build.sh                 version from the latest git tag (v0.1.0 -> 0.1.0), else 0.0.0
#   VERSION=0.2.0 ./build.sh
#
# Signing: with SIGN_IDENTITY set to a "Developer ID Application" identity in the keychain, the app
# is signed with it and, with NOTARY_PROFILE set (xcrun notarytool store-credentials), notarized
# and stapled. Without them it is signed ad hoc, which macOS accepts after the user's one-time
# "Open Anyway" in System Settings > Privacy & Security.
set -eu
cd "$(dirname "$0")"

VERSION="${VERSION:-$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)}"
VERSION="${VERSION:-0.0.0}"
BUILD="${BUILD:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
APP="build/OX Link.app"

rm -rf build dist
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" dist

for arch in arm64 x86_64; do
  swiftc -O -target "$arch-apple-macos13.0" -framework AppKit -framework Network -framework ServiceManagement \
    -o "build/OXLink-$arch" Sources/main.swift
done
lipo -create -output "$APP/Contents/MacOS/OXLink" build/OXLink-arm64 build/OXLink-x86_64
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" Info.plist > "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

codesign --force --options runtime --timestamp=none --sign "$SIGN_IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"

if [ "$SIGN_IDENTITY" != "-" ] && [ -n "${NOTARY_PROFILE:-}" ]; then
  ditto -c -k --keepParent "$APP" build/notarize.zip
  xcrun notarytool submit build/notarize.zip --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
fi

ditto -c -k --keepParent "$APP" "dist/OX-Link-$VERSION.zip"
mkdir -p build/dmg
cp -R "$APP" build/dmg/
ln -s /Applications build/dmg/Applications
hdiutil create -quiet -volname "OX Link $VERSION" -srcfolder build/dmg -format UDZO -ov "dist/OX-Link-$VERSION.dmg"
if [ "$SIGN_IDENTITY" != "-" ]; then codesign --force --sign "$SIGN_IDENTITY" "dist/OX-Link-$VERSION.dmg"; fi

(cd dist && shasum -a 256 OX-Link-* > SHA256SUMS.txt)
echo "Built OX Link $VERSION ($BUILD), signed with: $SIGN_IDENTITY"
cat dist/SHA256SUMS.txt

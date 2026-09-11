#!/bin/bash
# Build a signed DMG; refuse to label it ready until notarization succeeds.
set -euo pipefail
cd "$(dirname "$0")/.."
arch="${1:?Usage: package-release.sh arm64|x86_64}"
case "$arch" in arm64|x86_64) ;; *) exit 2 ;; esac
identity="${CDRIP_SIGN_IDENTITY:?Set a Developer ID Application identity}"
profile="${CDRIP_NOTARY_PROFILE:?Set the matching Apple team notarytool Keychain profile}"
bundle="$PWD/build/release/$arch/CD Rip.app"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$bundle/Contents/Info.plist")
staging="$PWD/build/dmg-$arch"
[ ! -e "$staging" ] || { echo "Staging already exists: $staging" >&2; exit 1; }
mkdir -p "$staging" dist
# Refresh notices before signing the outer bundle.
cp LICENSE "$bundle/Contents/Resources/LICENSE.txt"
cp -R ThirdParty "$bundle/Contents/Resources/"
for binary in "$bundle/Contents/Frameworks/"*.dylib "$bundle/Contents/Resources/Tools/"*; do
  codesign --force --options runtime --timestamp --sign "$identity" "$binary"
done
codesign --force --options runtime --timestamp --sign "$identity" "$bundle"
codesign --verify --deep --strict "$bundle"
# Staple the app too, so the copy dragged out of the DMG carries its ticket.
zip="$PWD/build/CD-Rip-$arch-notarization.zip"
ditto -c -k --keepParent "$bundle" "$zip"
xcrun notarytool submit "$zip" --keychain-profile "$profile" --wait
xcrun stapler staple "$bundle"
ditto "$bundle" "$staging/CD Rip.app"
ln -s /Applications "$staging/Applications"
cp docs/INSTALLATION.md "$staging/Read me.txt"
dmg="$PWD/dist/CD-Rip-$version-$arch.dmg"
hdiutil create -volname 'CD Rip' -srcfolder "$staging" -format UDZO "$dmg"
codesign --timestamp --sign "$identity" "$dmg"
xcrun notarytool submit "$dmg" --keychain-profile "$profile" --wait
xcrun stapler staple "$dmg"
xcrun stapler validate "$dmg"
spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg"
echo "Ready: $dmg"

#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
arch="${CDRIP_ARCH:-$(uname -m)}"
case "$arch" in arm64|x86_64) ;; *) echo "Unsupported architecture: $arch" >&2; exit 2 ;; esac
bash scripts/swift.sh build -c release --triple "$arch-apple-macosx14.0"
bin_dir="$(bash scripts/swift.sh build -c release --triple "$arch-apple-macosx14.0" --show-bin-path)"
bundle="${CDRIP_BUNDLE_PATH:-$PWD/build/CD Rip.app}"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
cp "$bin_dir/CDRip" "$bundle/Contents/MacOS/CDRip"
# Public binaries must not expose developer paths through Swift debug records.
xcrun strip -S "$bundle/Contents/MacOS/CDRip"
cp Assets/AppIcon.icns "$bundle/Contents/Resources/AppIcon.icns"
cat > "$bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleLocalizations</key><array><string>en</string></array>
<key>CFBundleName</key><string>CD Rip</string>
<key>CFBundleDisplayName</key><string>CD Rip</string>
<key>CFBundleIdentifier</key><string>digital.mykey.cdrip</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleExecutable</key><string>CDRip</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.4.0</string>
<key>CFBundleVersion</key><string>24</string>
<key>NSHumanReadableCopyright</key><string>© 2026 Mykey Digital. All rights reserved.</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
if [ -n "${CDRIP_AUDIO_PREFIX:-}" ]; then
  python3 scripts/bundle-audio-tools.py "$CDRIP_AUDIO_PREFIX" "$bundle"
fi
cp LICENSE "$bundle/Contents/Resources/LICENSE.txt"
if [ -d ThirdParty ]; then cp -R ThirdParty "$bundle/Contents/Resources/"; fi
codesign --force --sign - "$bundle"
printf 'Aplicație locală: %s\n' "$bundle"

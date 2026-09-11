# Building distributable releases

Release builds target macOS 14+ in separate arm64 and x86_64 packages. Build on
macOS with Swift 6, Xcode/Command Line Tools, Python 3, make and pkgconf installed.
For developer prerequisites, `brew install pkgconf` supplies pkg-config; it is not
required by people installing the finished app.

## Audio dependencies

```sh
bash scripts/build-audio-tools.sh arm64 /private/tmp/cdrip-audio
bash scripts/build-audio-tools.sh x86_64 /private/tmp/cdrip-audio
```

Use a build directory without spaces for upstream Autotools. The script verifies
SHA-256 checksums from `scripts/audio-sources.json`, builds shared libraries from
unmodified source and limits FFmpeg to the formats needed by CD Rip. Override
`CDRIP_PKG_CONFIG` if pkg-config is not on PATH. Build logs stay under the work
folder. The tools have their own licenses; see `ThirdParty/README.md`.

## App bundles

```sh
CDRIP_ARCH=arm64 \
CDRIP_AUDIO_PREFIX=/private/tmp/cdrip-audio/arm64/install \
CDRIP_BUNDLE_PATH="$PWD/build/release/arm64/CD Rip.app" \
bash scripts/build-app.sh

CDRIP_ARCH=x86_64 \
CDRIP_AUDIO_PREFIX=/private/tmp/cdrip-audio/x86_64/install \
CDRIP_BUNDLE_PATH="$PWD/build/release/x86_64/CD Rip.app" \
bash scripts/build-app.sh
```

The bundler recursively copies audio libraries, rewrites their dependency paths
relative to the bundle and rejects dependencies outside the build prefix or macOS
system libraries. Developer bundles are ad-hoc signed. Re-run the bundled tool
smoke checks after changing any dependency or build configuration.

## Signed and notarized DMGs

Configure your own Developer ID Application certificate and a matching Apple
notarytool Keychain profile, then run:

```sh
export CDRIP_SIGN_IDENTITY='Developer ID Application: Your Organization (TEAMID)'
export CDRIP_NOTARY_PROFILE='your-notary-profile'
bash scripts/package-release.sh arm64
bash scripts/package-release.sh x86_64
```

The packaging script signs nested binaries before the app, notarizes and staples
the app, creates a drag-to-Applications DMG, then signs, notarizes and staples the
DMG. It fails if validation fails. It does not upload a GitHub release. Each run
requires a fresh `build/dmg-<architecture>` staging directory and output DMG path;
archive earlier artifacts before rebuilding.

Publish the exact third-party source archives alongside the DMGs, including
`scripts/audio-sources.json`, `scripts/build-audio-tools.sh` and the bundling script.
Generate `SHA256SUMS` only after stapling, then verify downloads against it. Keep
notarization logs and physical test records outside the public source repository.

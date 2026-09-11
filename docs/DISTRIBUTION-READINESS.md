# Public beta validation — 0.4.0

CD Rip 0.4.0 is a public beta, not a broadly validated stable release.

## Completed checks

- 89 discovered automated tests passed, with live opt-in tests left disabled.
- Release executables built for arm64 and x86_64 with a macOS 14 deployment target.
- Audio tools and dynamic libraries bundled with relative dependency paths.
- Bundled MP3/FLAC encoding, decoding, artist/title tags, PNG artwork embedding and
  extraction passed. Compressed audio payload and decoded PCM remained unchanged
  after tagging; FLAC decoded back to the source PCM.
- Intel tools ran under Rosetta on Apple Silicon. Both native application builds
  launched successfully in isolated temporary preview workspaces.
- Developer ID signing, Apple notarization and stapled tickets are required by the
  release packaging script for both the app and the DMG.
- Application source is MIT-licensed. Third-party notices and corresponding source
  archives accompany the release.

## Remaining beta validation

Physical Intel testing, macOS 14 testing on a separate Mac, wider external-drive
coverage, fresh-machine permission flows and a complete AzuraCast acceptance run
remain outstanding. Earlier physical ripping tests used Apple Silicon/macOS 26.1.
Rosetta and synthetic audio tests do not replace physical hardware testing.

AccurateRip, drive offset calibration and audio fingerprint recognition are not
implemented. These capabilities are not advertised as available.

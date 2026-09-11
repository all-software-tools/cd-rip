# Public beta validation — 0.5.0

CD Rip 0.5.0 is a public beta, not a broadly validated stable release.

## Completed checks

- 105 discovered automated tests passed, with live opt-in tests left disabled.
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

Local AccurateRip v1/v2 checksums and manual offsets are implemented. Online
database access remains disabled pending approval. Automatic calibration and
audio fingerprint recognition are not implemented. No new AccurateRip hardware
validation is claimed. SFTP transfer tests use a local subprocess server. An additional opt-in localhost
SSH test passed password/key authentication, changed-host-key rejection and
byte-identical upload. Keychain UI authorization and wider production-server
compatibility testing remain pending.

# CD Rip

A native SwiftUI app for macOS that rips audio CDs from an external drive, converts tracks to MP3/FLAC, and prepares metadata for an AzuraCast radio library.

Current version: **0.5.0 public beta**. The user interface is in English.

## Features

- Audio extraction with `cd-paranoia`, read-report and sample-count checks, per-track progress, and cancellation.
- MP3 at 192/256/320 kbps, V0, FLAC, or MP3 + FLAC. One output folder with `MP3`, `FLAC`, and `WAV` subfolders; keeping WAV files is optional.
- Manual tracklists or OCR from a photo, with CD-column selection and individual track validation.
- Web research for metadata and artwork through Codex CLI or Claude Code CLI, for one track or every track in a session.
- Manual editing and **Save all**: tags, artwork, and `Artist - Title` filenames without audio recompression.
- Each session retains its own destination and saved settings. Returning to CD1 does not save files in CD2's folder.
- Tagging backups, interrupted-operation recovery, missing-file checks, and protection against concurrent workspace writes.
- Save metadata drafts when quitting, separately from writing tags to audio files.
- Optional SFTP upload of MP3/FLAC, with a save-metadata-first option, generic-name warnings, pinned SSH host keys, and password/SSH-key authentication.
- Local AccurateRip v1/v2 checksums, manual drive-offset profiles and distinct verification statuses. Online database access remains disabled pending approval.
- **About CD Rip** with the application version, copyright notice, and a link to [mykeydigital.ro](https://mykeydigital.ro).

## Download and install

Download the DMG for your Mac from [GitHub Releases](https://github.com/all-software-tools/cd-rip/releases/tag/v0.5.0-beta.1):

- **Apple Silicon**: Macs with an Apple M-series chip.
- **Intel**: experimental x86_64 build; physical Intel testing is pending.

Open the DMG and drag CD Rip into Applications. The audio tools are included; no
Homebrew installation is required for the packaged app. AI CLIs are optional and
must be installed and authenticated separately. See the [installation guide](docs/INSTALLATION.md)
and [product page](https://www.mykeydigital.ro/tools/cd-rip).

## Build from source

Swift 6 / Xcode and macOS 14+. Physical hardware testing has been performed on Apple Silicon running macOS 26.1; Intel and macOS 14 have not been tested on physical machines.

Install the external dependencies on Apple Silicon, then build and launch:

```bash
brew install libcdio-paranoia ffmpeg
bash scripts/build-app.sh
open 'build/CD Rip.app'
```

Source builds use audio tools from `/opt/homebrew/bin` or `/usr/local/bin` unless bundled tools are supplied. Release builds prefer their own bundled audio tools. Install AI CLIs separately and configure their paths in Settings.

```bash
codex login
claude auth login
```

The app checks for subscription-based authentication. Requests count toward your account's usage limits; there is no automatic fallback to API keys. Any extra usage enabled on your account remains controlled by the provider.

## Workflow

1. Connect the external drive with an audio CD and click **Detect**.
2. Choose the output folder and profile in Extraction, select tracks, and start extraction.
3. Enter or import the tracklist; verify physical track numbers, artists, and titles.
4. Fill in metadata manually or with AI, then review the proposals.
5. Click **Save all** and check the destinations shown for that session.
6. Optionally configure SFTP in Settings, then use **Upload via SFTP** in Metadata. See the [SFTP guide](docs/SFTP-UPLOAD.md).

The CD is temporarily unmounted for direct reading and remounted afterward. Do not run another ripper against the same drive at the same time.

## Testing and development

```bash
bash scripts/swift.sh build
bash scripts/swift.sh test
```

Default tests do not use the network, AI subscriptions, or CD hardware. With FFmpeg/ffprobe available, they generate synthetic audio and verify conversion, tagging, recovery, and audio preservation. Live tests are opt-in and must not be enabled automatically in CI.

To use a separate development workspace:

```bash
open -n 'build/CD Rip.app' --args --data-dir /path/to/workspace-qa
```

Use distinct data directories for separate instances.

## Local data and distribution

- Preferences and sessions: `~/Library/Application Support/CDRip/workspace.json`.
- Intermediate audio, reports, and backups: `~/Library/Application Support/CDRip/AudioSessions`.
- Downloaded artwork: `~/Library/Application Support/CDRip/Covers`.
- `--data-dir` changes the workspace directory, not every internal app directory.
- Local data, audio, builds, logs, and signing material are excluded from Git.

The developer build script uses ad-hoc signing by default. Public DMGs are prepared
with Developer ID signing and Apple notarization. Signing credentials are never
included in the repository. See [release build instructions](docs/BUILDING-RELEASES.md)
and [distribution validation](docs/DISTRIBUTION-READINESS.md).

## Current limitations

Audio fingerprint recognition and automatic drive-offset calibration are not implemented. AccurateRip checksums are calculated locally, but online database access is disabled pending third-party approval; this release does not certify AccurateRip matches. See [verification details](docs/ACCURATERIP.md). OCR and AI research require human review. A decodable conversion does not certify a bit-perfect CD read. Only a single mounted audio CD is supported; mixed-mode, multisession, and pre-emphasis are not supported. Upload can be started manually through SFTP to a compatible server; there is no AzuraCast station API integration or automatic post-rip transfer. SFTP requires an Ed25519 server host key.

## Contributing

Bug reports, documentation improvements and pull requests are welcome. Read
[CONTRIBUTING.md](CONTRIBUTING.md) for setup and contribution guidelines, and
[SECURITY.md](SECURITY.md) to report a vulnerability privately.

## License

Copyright © 2026 [Mykey Digital](https://mykeydigital.ro).

CD Rip source code is available under the [MIT License](LICENSE). You may use,
modify and redistribute it, including commercially, while retaining the copyright
and license notice. Contributions are welcome; notification of reuse is optional.

Bundled audio tools retain their own licenses. See [third-party notices](ThirdParty/README.md).
Exact corresponding source archives and build scripts are provided with the release.

# CD Rip — installation and first use

CD Rip 0.5.0 is a public beta for macOS 14 or later.

1. In Apple menu > About This Mac, check whether your Mac has an Apple M-series
   chip (Apple Silicon) or an Intel processor. Download the matching DMG.
2. Open the DMG and drag CD Rip to Applications. Eject the disk image afterward.
3. Open CD Rip from Applications. Grant folder and removable-drive access when
   macOS asks. Wait for the permission dialog instead of repeatedly starting a rip.
4. Connect an external CD/DVD drive and insert an audio CD. Click Detect.
5. Select your output folder and quality profile, choose tracks and start ripping.
6. Paste a tracklist or use a photo. Verify the selected CD and track mapping.
7. Edit metadata or request AI research, review the proposals, then Save all.
8. Optionally configure SFTP in Settings and choose Upload via SFTP in Metadata.
   Trust the server fingerprint only after checking it with your administrator.
   Passwords are stored in macOS Keychain; SSH key/agent authentication is also supported.

Audio tools are included: Homebrew is not required for downloaded DMG builds.
Codex CLI or Claude Code CLI must be installed and signed in separately if you
want AI features. Configure the executable path in Settings and test the connection.
Manual metadata editing and audio conversion do not need an AI account.

MP3, FLAC and optional WAV files use separate subfolders inside the chosen output
folder. Each session remembers its destination. Save all displays the destinations
before writing. Deleting WAV is optional and happens only after requested output
formats have been verified. Tagging does not recompress the audio.

Session data is stored in ~/Library/Application Support/CDRip. Replacing the app
does not remove it. Read reports and recovery files stay in internal app storage.
Do not delete that directory if you want to retain sessions or recovery data.

Current limits: physical testing on Apple Silicon/macOS 26.1; Intel is experimental
pending physical hardware testing. AccurateRip online access awaits approval. Checksums are local, and known drive
offsets can be entered manually. Automatic calibration and audio recognition are
not implemented. AI suggestions need human review.
Only one mounted audio CD is supported; mixed-mode, multisession, pre-emphasis,
data CDs and DVD audio are unsupported. SFTP upload is optional and started manually; there is no AzuraCast API integration.

Source, issues and release checksums:
https://github.com/all-software-tools/cd-rip

Website: https://www.mykeydigital.ro/tools/cd-rip
Copyright © 2026 Mykey Digital. Application source: MIT License.
Third-party audio components retain their own licenses (included in the app).

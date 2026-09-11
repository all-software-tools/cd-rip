# Optional SFTP upload

Available in the 0.5.0 public beta.

In **App settings → SFTP upload**, enter the hostname, port, username and existing absolute remote folder. Choose password authentication or an SSH key/agent. Store passwords using **Store password in Keychain**; passwords never enter workspace/session JSON, batch files or command arguments. macOS may ask to authorize Keychain access. Encrypted private keys must already be unlocked in the SSH agent.

Use **Fetch server fingerprint**, compare the displayed SHA256 fingerprint with an independent value from your server administrator, and explicitly trust it. Save preferences. The initial implementation requires an Ed25519 server host key. Server key changes fail closed; there is no automatic trust or fallback to an unverified host. **Test SFTP connection** checks authentication and the remote folder without uploading music; write access is checked at upload time.

After extraction, open **Metadata → Upload via SFTP**:

- Select MP3, FLAC, or both. Only completed extracted outputs are eligible; recovery WAVs and reports are excluded.
- Leave **Save metadata and filenames before uploading** enabled to save the current drafts into local files first. Upload proceeds only if those saves succeed. AI lookup is optional and is not automatically triggered.
- Disable that option to upload the currently saved audio files as they are, including any tags/cover already embedded. This does not strip metadata.
- Generic names such as Track01 and unsaved metadata trigger a warning requiring an explicit **Upload anyway**. Unverified AccurateRip status is also disclosed. A read failure or persistent mismatch does not become uploadable through this warning.

Every upload creates a fresh `CDRip-<UUID>/MP3` and/or `FLAC` directory under the configured remote folder. This prevents ordinary retries from overwriting earlier uploads. Each file uploads to a unique `.part` name and is renamed only after the SFTP transfer completes. Progress counts completed files. Cancel or a connection failure stops the remaining uploads; completed files and possible `.part` files remain on the server. Retrying creates a new folder; automatic resume/deduplication is not implemented. Local audio is not removed by upload.

The client uses macOS OpenSSH, strict pinned host-key checks, bounded connection/stall/transfer timeouts and cancellable processes. It does not use the user's SSH config, run remote shell commands, strip tags, or recompress audio. A successful transfer means SFTP acknowledged the operations; the client does not independently read back/hash remote files.

Validation includes settings compatibility, unsafe-path rejection, generic-name detection, failure/cancellation behavior, and a real local SFTP protocol test with special filenames and byte-for-byte comparisons. A separate opt-in localhost SSH test verifies password authentication through an askpass fixture, private-key authentication, pinned-host verification, rejection of wrong passwords/changed keys, and byte-identical uploads. It does not touch Keychain. Production-server compatibility and the macOS Keychain authorization flow still require user validation; no user server has been contacted.

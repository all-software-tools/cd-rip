# Contributing to CD Rip

Thank you for helping make CD Rip useful to more people. Bug reports, documentation,
accessibility improvements and code contributions are welcome.

## Before you start

Open an issue for a new feature or substantial change so we can agree on scope.
For a bug, include your macOS version, CPU architecture, CD drive model, steps to
reproduce and the exact error. Remove personal paths, credentials and music files
from diagnostics before sharing them. Do not upload copyrighted recordings.

## Development

Use Swift 6 and macOS 14 or later. See the README for audio dependencies.

```sh
bash scripts/swift.sh build
bash scripts/swift.sh test
```

Default tests use local fixtures. Live AI/network/CD tests are opt-in; do not enable
them in CI or run them using another person's account without authorization.
Use a separate `--data-dir` for development so your real sessions stay isolated.
For live OCR diagnostics, `CDRIP_CLAUDE_PATH` can override the Claude executable.

## Pull requests

1. Fork the repository and create a branch for your change.
2. Keep changes focused and describe the problem and resulting behavior.
3. Run relevant checks and report what was tested, including platform limitations.
4. Submit a pull request. A maintainer reviews it before merging.

Preserve audio during metadata changes, keep UI work on the main actor, and use
atomic persistence. Never present simulated tests as physical CD verification.
Keep the UI in English. Do not commit sessions, audio, keys or generated bundles.

By submitting a contribution, you agree to license your contribution under this
project's MIT License. Existing third-party components retain their own licenses.
Treat contributors respectfully and give specific, constructive feedback.

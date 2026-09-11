# CD Rip contributor guidelines

- Native SwiftUI macOS app, Swift 6. Keep the user interface in English.
- Keep UI state on the main actor and blocking I/O in asynchronous services.
- Persist workspace changes atomically and preserve recovery data.
- Preserve physical track IDs when selecting a subset of a CD.
- Keep manual metadata, AI proposals and source evidence distinguishable.
- Never recompress audio merely to update tags.
- Do not claim hardware validation from simulations or synthetic tests.
- Build: `bash scripts/swift.sh build`; test: `bash scripts/swift.sh test`.
- Bundle: `bash scripts/build-app.sh`.
- Live AI, network and hardware tests are opt-in. Never enable them automatically in CI.
- Do not commit credentials, signing material, user sessions, audio or generated builds.

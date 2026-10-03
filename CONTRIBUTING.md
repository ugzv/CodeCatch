# Contributing

CodeCatch is a macOS 15+ Swift package. Swift 6 and the Apple Command Line
Tools are sufficient; Xcode also works. Use the checked-in `Package.resolved`.

```sh
scripts/test.sh --force-resolved-versions
swift build -c release --scratch-path .build-release --force-resolved-versions
```

These commands need no mail accounts, Full Disk Access, Accessibility, signing
certificate or release secrets. Tests use synthetic messages, isolated settings,
in-memory vaults and private pasteboards. CI runs them on Apple silicon and Intel.
Do not use a personal inbox or vault as a test fixture.

Keep a change focused on a failure or a concrete simplification. For bugs, first
add a failing case to the closest existing test. Preserve behavioral assertions
when moving code. Tests around sensitive actions should exercise rejection,
cancellation and stale state, not just the successful path.

`Sources/CodeCatchCore` contains parsing and deterministic logic; macOS adapters
and UI live in `Sources/CodeCatch`. See [ARCHITECTURE.md](ARCHITECTURE.md) for the
privacy boundaries. New sources deliver `IncomingMessage` through the existing
ingestion path. Do not create another clipboard, storage or authentication path.

Never commit inbox exports, real verification links, credentials, signing keys
or screenshots containing personal data. Use `example.com` or `.invalid` for
synthetic addresses. Report exposure bugs through [SECURITY.md](SECURITY.md).

Running the actual app is different from running tests: it can read the current
user's configured sources. Use a separate macOS account and synthetic messages
for permission, lock, sleep/wake and update checks. Signed installation and
notarization are maintainer steps described in [README.md](README.md#releasing).

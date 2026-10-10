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
Add a line to `Tests/CodeCatchCoreTests/code-samples.txt` for every new code
format or false positive. `@Local` stands in for `@State`, whose macro plugin
only ships with Xcode.

Never commit inbox exports, real verification links, credentials, signing keys
or screenshots containing personal data. Use `example.com` or `.invalid` for
synthetic addresses. Report exposure bugs through [SECURITY.md](SECURITY.md).

Running the actual app is different from running tests: it can read the current
user's configured sources. Use a separate macOS account and synthetic messages
for permission, lock, sleep/wake and update checks.

## Debug tools

Debug builds have extra tools, such as `--probe` (prints the codes each mail
account would give, masked), `--snapshot <dir>` (renders the UI to PNGs) and
`--import-env`. The full list is in `Sources/CodeCatch/App`. Run them with
`scripts/debug.sh <flag>`; it signs the build like a release, so the Keychain
doesn't ask for your password after every rebuild. Release builds leave these
tools out.

Preview the site with `python3 -m http.server --directory site`.

## Releasing

| Command | Result |
|---|---|
| `scripts/install.sh --build-only` | Tests, then builds a signed universal app in `.build-release/` |
| `scripts/install.sh --release` | Also makes `CodeCatch.dmg`, notarizes it, and writes `site/appcast.xml` |
| `scripts/install.sh --publish` | Also uploads the DMG as a GitHub release, then commits and pushes `site/appcast.xml` |

CI then deploys `site/` to Cloudflare Pages, and installed copies update
themselves from `https://codecatch.app/appcast.xml`.

A release needs:

- a Developer ID certificate (`Developer ID Application` in the login keychain;
  set `CODECATCH_IDENTITY` to pick another)
- a `notarytool` Keychain profile named `codecatch` (or set `CODECATCH_NOTARY_PROFILE`)
- Sparkle's EdDSA key in the Keychain
- `uvx`, for `dmgbuild`
- `gh` and push access to `main`, with `main` checked out, pushed and clean

The build number is the commit count plus 100 (`CODECATCH_BUILD_NUMBER`
overrides it). Before a release, test the download on a fresh macOS account: on
Intel, on a Mac without Touch ID, and through Messages, mail and password unlock.

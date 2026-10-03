<div align="center">
  <h1>CodeCatch</h1>
  <p><em>Sign-in codes, caught the moment they arrive.</em></p>
  <p>
    <a href="https://github.com/ugzv/CodeCatch/actions/workflows/ci.yml"><img src="https://img.shields.io/github/actions/workflow/status/ugzv/CodeCatch/ci.yml?branch=main&style=flat-square&label=tests" alt="Tests"></a>
    <a href="https://github.com/ugzv/CodeCatch/releases/latest"><img src="https://img.shields.io/github/v/release/ugzv/CodeCatch?style=flat-square" alt="Latest release"></a>
    <a href="LICENSE"><img src="https://img.shields.io/badge/license-GPL_v3-blue.svg?style=flat-square" alt="License: GPL v3"></a>
    <img src="https://img.shields.io/badge/macOS-15%2B-black?style=flat-square" alt="macOS 15 or later">
  </p>
  <p><a href="https://codecatch.app/download/CodeCatch.dmg"><b>Download for Mac</b></a> · <a href="https://codecatch.app">codecatch.app</a> · <a href="https://codecatch.app/privacy/">Privacy</a> · <a href="https://codecatch.app/changelog/">Changelog</a></p>
  <img src="site/assets/og.png" alt="CodeCatch banner showing a verification code ready to paste" width="720">
</div>

CodeCatch is a Mac menu bar app. When a sign-in code or sign-in link arrives in
**Messages** or your **mail**, it copies it. Press ⌘V and you're in, in any
browser or app.

## What it does

- **Copies new codes for you.** The code is on your clipboard when it arrives and
  is cleared after 90 seconds. It stays on this Mac and is marked so clipboard
  managers skip it.
- **Shows a small banner** with the service, the code and a **Copy** button. It
  never takes focus from what you were typing.
- **Keeps recent codes in the menu bar.** Click one to copy it. History is 7 days
  by default.
- **Handles sign-in links.** It shows where a link leads and warns you when that
  is a different site from the sender's. It never opens a link by itself.
- **Reads Messages and mail.** iMessage and forwarded SMS, the Mail app's
  inboxes, Gmail and any IMAP account. It only reads; it never changes a mail.
- **Shows your Bitwarden codes.** Import your two-step logins once, then search
  them next to received codes. They stay locked behind your Mac password or
  Touch ID.
- **Can type the code for you** (off by default), including into
  one-box-per-digit fields.
- **Works from the keyboard.** ⌃⌥⌘C copies the latest code. ⌃⌥⌘F opens search.
  Launchers can use `codecatch://search?q=github`.
- **Finds codes it missed.** **Can’t find your code?** lists recent emails that
  look like verification mail, so you can copy the code yourself.
- **Lets you fix mistakes.** Right-click → **Not a Code** or **Ignore All from …**.
  Ignored senders can be restored in Settings → Sources.
- **Gives you control.** Turn codes, sign-in links, Bitwarden or a single mail
  account on and off in Settings. Each source shows when it was last checked.
- **Reads about 35 languages**, including English, German, Slovenian, Russian,
  Arabic, Chinese, Japanese and Korean.
- **Stays private.** Hidden from screen sharing and recordings. Optional blur
  until hover, and optional clearing when the Mac locks.

## Install

You need **macOS 15 or later** and a Mac login password. It runs on Apple silicon
and Intel. Touch ID is optional.

[Download CodeCatch.dmg](https://codecatch.app/download/CodeCatch.dmg) (signed and
notarized; it updates itself), or build from source:

```bash
scripts/install.sh
```

This runs the tests, builds the app, installs it to
`~/Applications/CodeCatch.app` and opens it. You only need Apple's Command Line
Tools, not Xcode. CodeCatch opens at login by default (Settings → General).

To get SMS codes on your Mac, turn on **Text Message Forwarding** on your iPhone.

### Permissions

macOS asks once, in System Settings → Privacy & Security.

| Permission | Why | Without it |
|---|---|---|
| **Full Disk Access** | To read Messages (`~/Library/Messages/chat.db`) and, if you turn it on, Apple Mail (`~/Library/Mail`) | Messages and Apple Mail show "Needs Full Disk Access" |
| **Accessibility** | Only for *Automatically Type Codes* | Codes are copied, not typed |

By default CodeCatch never types into other apps. You paste the code yourself.
If you turn on *Automatically Type Codes*, a new code is typed into the field
that has focus when it arrives.

### Mail

**Apple Mail.** Settings → Sources → turn on *Apple Mail*. There is nothing to
sign in to. CodeCatch reads the inboxes the Mail app already has, and sees new
mail while Mail is open.

**Gmail and other accounts.** Settings → Sources → *Add Account…*, then pick
Google or another IMAP provider. Gmail needs an
[app password](https://support.google.com/accounts/answer/185833). Google only
offers app passwords when 2-Step Verification is on, and not for some managed or
Advanced Protection accounts.

CodeCatch only reads mail (`EXAMINE` and `BODY.PEEK` over IMAP IDLE). It never
marks, moves or changes a message.

**Sign in with Google** is not public yet. It needs Google's verification first.
The button appears only when a Google OAuth client is set up.

### Bitwarden codes

If you keep two-step codes in Bitwarden, CodeCatch can show them next to the
codes you receive.

1. Install the [Bitwarden CLI](https://bitwarden.com/help/cli/): `brew install bitwarden-cli`.
2. Sign in once in Terminal: `bw login`.
3. In CodeCatch, open Settings → Sources → Bitwarden → *Set Up…* and follow the
   checklist.
4. Enter your master password, check the list under **Review Import**, then
   **Save Changes**.

Use **Refresh…** after you change two-step logins in Bitwarden. To switch between
the US (`bitwarden.com`) and EU (`bitwarden.eu`) server, run `bw logout` first.

How it stays safe:

- CodeCatch keeps only each login's name, username, site and TOTP secret. The
  CLI's reply holds your decrypted vault in memory for a moment; nothing else
  from it is kept.
- If CodeCatch unlocked the CLI vault, it locks it again.
- Codes are made on your Mac, offline (RFC 6238, `otpauth://` and Steam).
- CodeCatch starts locked. You unlock with your Mac password or Touch ID to see
  or copy a code.
- It locks again on sleep, on screen lock, or when you click the padlock. Locking
  clears the loaded logins from memory, hides received codes, and clears the
  clipboard if CodeCatch's copy is still there.

## Privacy

Codes and messages stay on your Mac. The full list of what CodeCatch reads, keeps
and connects to is at [codecatch.app/privacy](https://codecatch.app/privacy/).

**In memory only**

- Received codes. They are read again from Messages and mail at launch.

**On disk**

- Settings, in UserDefaults. Dismissed messages are saved by their source ID,
  without the code or link. Pinned and recent logins are saved as Bitwarden IDs,
  never as codes or account names.
- Mail passwords and imported Bitwarden TOTP secrets, in your login Keychain
  (service `com.uros.codecatch`). Builds signed by the same team read them
  without asking. Any other app gets a Keychain prompt.
- Cached service logos, in `~/Library/Caches/CodeCatch/Icons`.

The Bitwarden lock is an app lock: CodeCatch asks macOS to authenticate you each
session. It is not a separate biometric rule on the Keychain item. *Remove* in
Settings deletes the item.

**Network**

- Your mail servers, for the accounts you add.
- `codecatch.app`, to check for updates.
- Google's favicon service, for service logos. Google sees your IP address and
  the service's domain. CodeCatch never contacts the service's own site for a
  logo. Turn off **Show Service Logos** in Settings → Privacy to stop this.
- Bitwarden, only when you import or refresh.

## Alternatives

Looking for a 2FHey or MessAuto alternative that also reads mail, catches sign-in
links (magic links) and works in Chrome, Arc and Firefox? See
[CodeCatch vs 2FHey](https://codecatch.app/vs/2fhey/) and
[CodeCatch vs MessAuto](https://codecatch.app/vs/messauto/).

## Check it works

Open the menu → ⋯ → **Show Test Code**. A banner appears with a random code.

## Develop

Start with [CONTRIBUTING.md](CONTRIBUTING.md). It explains how to build and test
without touching your own mail or messages.
[ARCHITECTURE.md](ARCHITECTURE.md) explains how data flows and where the privacy
limits are.

```bash
scripts/test.sh    # run all tests
swift build && .build/debug/CodeCatch --snapshot /tmp/snap -autoCopy NO -showHUD NO -material    # render the UI to PNGs
swift scripts/make-icon.swift /tmp/AppIcon.icns /tmp/icon-preview.png    # redraw the fallback icon
```

Debug builds have extra command-line tools. Release builds leave them out, so a
shipped app can never print inbox data.

| Flag | What it does |
|---|---|
| `--probe` | Signs in to each mail account and prints the codes it would find, masked |
| `--probe-apple-mail` | The same for the Mail app's store |
| `--probe-google` | Checks the Google OAuth client and Gmail sign-in |
| `--import-env path/to/.env` | Imports mail passwords (`X_USER` + `X_PASS` pairs) and `GOOGLE_CLIENT_ID/SECRET`. Also in Settings as *Import from .env…* |
| `--snapshot <dir>` | Renders the UI to PNGs |

### Releasing

| Command | Result |
|---|---|
| `scripts/install.sh --build-only` | Tests, then builds a signed universal app in `.build-release/`. Does not install it |
| `scripts/install.sh --release` | Also makes `CodeCatch.dmg`, notarizes it, and writes the update feed to `site/appcast.xml` |
| `scripts/install.sh --publish` | Also uploads the DMG as a GitHub release, then commits and pushes `site/appcast.xml` |

CI then deploys `site/` to Cloudflare Pages, and installed copies update
themselves from `https://codecatch.app/appcast.xml`.

A release needs:

- a Developer ID certificate (`Developer ID Application` in the login keychain;
  set `CODECATCH_IDENTITY` to pick another)
- a `notarytool` Keychain profile named `codecatch` (or set `CODECATCH_NOTARY_PROFILE`)
- Sparkle's EdDSA key in the Keychain
- `uvx`, for `dmgbuild`
- `gh` and push access to `main`, with `main` checked out and already pushed

The working tree must be clean. The build number is the commit count plus 100
(`CODECATCH_BUILD_NUMBER` overrides it) and must be higher than the last one in
the appcast. The source commit is recorded in the app as
`CodeCatchSourceRevision`.

Before a release, test the download on a fresh macOS account: on Intel, on a Mac
without Touch ID, and through Messages, mail and password unlock setup.

### Layout

| Path | What lives there |
|---|---|
| `Sources/CodeCatchCore` | Pure, tested logic: `CodeExtractor` (code, lifetime, service), `SignInLink`, `ServiceIdentity`, `MIME`, `TypedStream`, `TOTP`, `VaultCode` |
| `Sources/CodeCatch/App` | Entry point and debug-only CLI (`--import-env`, `--probe…`, `--snapshot`, `--preview-recovery`) |
| `Sources/CodeCatch/Model` | `AppModel` (codes, sources, actions), `SourceMonitor` (starts, restarts and reports on each source), `CodeSearch`, `RecoveryInbox`, `CodeItem`, `IncomingMessage`, `Prefs` |
| `Sources/CodeCatch/Mail` | `IMAPConnection`, `MailWatcher` (IDLE), `MailAccount`, `GoogleOAuth`, `EnvImport`, `AppleMailStore` (the Mail app's store) |
| `Sources/CodeCatch/Messages` | `LocalWatcher` (polls a local store), `MessagesStore` (`chat.db`) |
| `Sources/CodeCatch/Vault` | `BitwardenCLI` (status, server, unlock → sync → list → lock), `VaultSession` (the app lock), `VaultStorage` (Keychain item behind macOS authentication), `VaultChanges` (import review) |
| `Sources/CodeCatch/System` | macOS glue: clipboard, key typing, Accessibility, hot keys, login item, Keychain secrets, Sparkle updates |
| `Sources/CodeCatch/UI` | `CodeCard`, `Banner`, `MenuBar`, `Settings`, shared `Components` |
| `Tests/CodeCatchCoreTests` | One file per Core type; `code-samples.txt` is the extraction corpus — add a line for every new format or false positive |
| `Tests/CodeCatchTests` | App regressions: dismissal privacy, clipboard, mail retries and Keychain error handling |
| `Resources` | `Info.plist`, `AppIcon.icon` (Icon Composer layers, compiled when Xcode is present) — the fallback `.icns` is generated into the build directory |
| `scripts` | `install.sh` (test, build, sign, install, release), `test.sh`, `make-icon.swift`, the DMG's `dmg-settings.py` and `make-dmg-background.swift` |
| `site` | The codecatch.app landing page: static HTML, CSS and one script, no build step. Preview with `python3 -m http.server --directory site` |

A new source hands `IncomingMessage`s to `AppModel.ingest`. Everything after that
(finding the code, removing duplicates, banner, clipboard, menu) is shared.
`@Local` stands in for `@State`, whose macro plugin only ships with Xcode.

## License

[GPL-3.0](LICENSE). If you share a fork or a build, you must publish its source
under the same license. To report a security problem, see [SECURITY.md](SECURITY.md).

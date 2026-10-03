# Architecture and privacy boundaries

CodeCatch has two Swift targets. `CodeCatchCore` handles extraction, MIME,
service names and TOTP calculation without UI or account access. `CodeCatch`
contains macOS adapters, orchestration and SwiftUI views. Sparkle is the only
package dependency; its resolved version is checked in.

## Received messages

`MessagesStore` and `AppleMailStore` read local stores through `LocalWatcher`.
`MailWatcher` uses TLS IMAP with `EXAMINE` and `BODY.PEEK`. `SourceMonitor` owns
worker lifetimes and rejects callbacks from replaced workers using generations.
Every source delivers `IncomingMessage` to `AppModel.ingest` for extraction,
deduplication, history limits and announcement decisions.

Received codes and recovery messages stay in memory. Dismissal identifiers,
source account configuration and preferences use UserDefaults. `Prefs` supplies
defaults and the history limit; model, monitor, search and account persistence
must use the same injected store. Tests must not fall back to `.standard`.

Recovery retains at most 20 messages for 30 minutes, bounds their text and
requires explicit selection and an unlocked session before copying.

## Authentication and output

`VaultSession` starts locked. macOS authentication loads saved vault entries;
a generation check prevents a pending unlock from winning after a lock or
cancellation. Sleep, screen lock and manual lock clear the loaded vault. Received
messages may still arrive while locked, but copy/open/type actions require unlock.
The optional clear-on-lock setting also removes received history.

`VaultStorage` owns vault serialization; `Secrets` owns login-Keychain calls.
This is an app session lock, not a separate biometric Keychain access-control
policy. It does not defend against a compromised macOS account or process memory
inspection. Swift strings and Data are not guaranteed to be securely zeroed.

All copy paths use `Clipboard`. Copies disable Universal Clipboard and advertise
concealed/transient markers. Those markers are requests to other apps, not access
control. Timeout and lock cleanup only clear a clipboard value still owned by
CodeCatch. Auto-type is opt-in; sign-in links open only after a user action.

## Network boundaries

| Component | Destination and purpose |
|---|---|
| `MailWatcher` | Configured IMAP server over TLS; inbox reads |
| `GoogleOAuth` | Google authorization/token endpoints; optional sign-in |
| `BitwardenCLI` | User's configured Bitwarden service; explicit sync/import |
| `IconStore` | Google favicon service only; receives the inferred domain, never message text or codes |
| `Updater` | codecatch.app for the Sparkle feed and signed release downloads |

Logos are on by default and can be disabled in Privacy. Only Google favicon
hosts are allowed; redirects to service websites are rejected. Google receives
the requesting IP address and domain. Other servers receive ordinary connection
metadata for their respective features. Opening a
sign-in link also sends its token to the chosen destination. There is no app
analytics or crash-upload pipeline. The public [privacy page](site/privacy/index.html)
must stay consistent with implementation changes.

## Verification and releases

Unit tests exercise deterministic parsing and injected adapters; they do not
prove real macOS permission grants, hardware support or notarization. A release
still needs signed-bundle checks and a fresh-account smoke test for source setup,
authentication, lock/sleep/wake, clipboard cleanup and updating an existing install.

When moving the repository to CodeCatch, preserve Git history or explicitly
choose a build number above the last shipped one. Keep the bundle identifier,
Keychain service, signing identity, URL scheme, Sparkle key and update feed stable
for existing installations. Update repository links separately after the move,
enable private vulnerability reporting and require the CI checks before merging.

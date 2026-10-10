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

## Agent access

`codecatch` (`Sources/CodeCatchCLI`, shipped as `Contents/Helpers/codecatch`)
talks to the running app over a Unix socket in Application Support (folder 0700,
socket 0600). There is no TCP port, token or URL scheme that gives out codes.
Each side checks the other. The app accepts only the same user and names the
caller after the first validly signed app up its parent processes. The process's
own name is shown as unverified. The CLI sends nothing unless the socket's owner
is CodeCatch, signed by the CLI's own team.

`AgentAccess` keeps the switch and the "always allow" rules in the login
Keychain, so `defaults write` can't turn them on. A release needs Touch ID or
the Mac password on the request's card every time, or a rule: an app (bundle ID
and team), one site or all. Allow All, turned on with the same authentication,
releases to any caller; it shares the hourly cap and never covers a text that
names no site. Sign-in links go to agents only while their own switch is on
(also behind authentication), then under the same card, rules and Allow All. An approval covers the
one item the card showed. Mail matches by the sender's registrable domain only.
Links go out only from verified senders, to the requested site, and never for a
password reset or a link the lookalike check warns about. While a request waits,
new codes skip auto-copy, auto-type and the banner. Lock and sleep cancel a
pending card; rules keep working while locked, so unattended runs can finish.
Three denials in a row turn access off, and rules give out at most 20 codes an
hour before asking again. The log keeps who asked, the site and the outcome,
never the code. None of this stops a program that already has Full Disk Access
from reading Messages or Mail directly.

## Network boundaries

| Component | Destination and purpose |
|---|---|
| `MailWatcher` | Configured IMAP server over TLS; inbox reads |
| `GoogleOAuth` | Google authorization/token endpoints; optional sign-in |
| `BitwardenCLI` | User's configured Bitwarden service; explicit sync/import |
| `IconStore` | Google favicon service only; receives the inferred domain, never message text or codes |
| `Updater` | codecatch.app for the Sparkle feed (with a random install ID, build, macOS version and Mac model, counted by `functions/_middleware.js`) and signed release downloads |

Logos are on by default and can be disabled in Privacy. Only Google favicon
hosts are allowed; redirects to service websites are rejected. Google receives
the requesting IP address and domain. Other servers receive ordinary connection
metadata for their respective features. Opening a
sign-in link also sends its token to the chosen destination. Apart from that install count, there is
no app analytics or crash-upload pipeline. The public [privacy page](site/privacy/index.html)
must stay consistent with implementation changes.

## Verification and releases

Unit tests exercise deterministic parsing and injected adapters; they do not
prove real macOS permission grants, hardware support or notarization. A release
still needs signed-bundle checks and a fresh-account smoke test for source setup,
authentication, lock/sleep/wake, clipboard cleanup and updating an existing install.

Keep the bundle identifier, Keychain service, signing identity, URL scheme,
Sparkle key and update feed stable for existing installations. Build numbers must
keep increasing; the public history restarted after build 52, so builds are the
commit count plus 100.

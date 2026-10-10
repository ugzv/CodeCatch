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

CodeCatch is a Mac menu bar app. When a 2FA verification code or sign-in link
arrives in **Messages** or your **mail**, it copies it. Press ⌘V and you're in,
in any browser or app.

## What it does

- **Copies new codes.** The code is on your clipboard when it arrives and is
  cleared after 90 seconds.
- **Shows a small banner** that never takes focus from what you're typing.
- **Keeps recent codes in the menu bar.** Click one to copy it.
- **Handles sign-in and password reset links.** It warns you when a link leads
  to a different site than the sender's, and never opens one by itself.
- **Reads Messages and mail:** iMessage, forwarded SMS, the Mail app, Gmail,
  Outlook and any IMAP account.
- **Shows your Bitwarden codes** next to the ones you receive.
- **Lets your agents sign in, with your OK** (off by default).
- **Can type the code for you** (off by default).
- **Works from the keyboard.** ⌃⌥⌘C copies the latest code. ⌃⌥⌘F opens search.
- **Reads about 35 languages.**
- **Stays private.** Hidden from screen sharing, with optional blur and
  clearing when the Mac locks.

## Install

You need **macOS 15 or later** on Apple silicon or Intel, and a Mac login
password.

[Download CodeCatch.dmg](https://codecatch.app/download/CodeCatch.dmg). It is
signed, notarized and updates itself. To build from source, run
`scripts/install.sh`. You only need Apple's Command Line Tools.

For SMS codes, turn on **Text Message Forwarding** on your iPhone.

To check it works, open the menu → ⋯ → **Show Test Code**.

### Permissions

| Permission | Why |
|---|---|
| **Full Disk Access** | To read Messages and Apple Mail |
| **Accessibility** | Only to type codes for you |

### Mail

- **Apple Mail:** Settings → Sources → turn on *Apple Mail*. No sign-in needed.
- **Gmail, Outlook and IMAP:** Settings → Sources → *Add Account…*. Gmail takes
  Sign in with Google (beta) or an
  [app password](https://support.google.com/accounts/answer/185833). Outlook
  takes Sign in with Microsoft (beta).

CodeCatch only reads mail. It never marks, moves or changes a message.

### Bitwarden

1. Install the [Bitwarden CLI](https://bitwarden.com/help/cli/) and run
   `bw login` once.
2. In CodeCatch, open Settings → Sources → Bitwarden → *Set Up…*.

CodeCatch keeps only each login's name, username, site and TOTP secret, in your
Keychain. It makes codes offline, and you unlock them with Touch ID or your Mac
password.

### Agents

Claude Code, Codex and scripts can ask for a code while they sign in for you.

1. Open Settings → Agents and turn on **Let Agents Ask for Codes**. This also
   adds `codecatch` to `/usr/local/bin`.
2. Click **Connect** next to Claude Code, Codex or Cursor. This adds a small
   skill the agent loads only when it needs a code. For other agents, copy the
   text under **Other Agents** into their instructions.

```bash
codecatch get github.com --json
```

You approve each code with Touch ID, choose **Always Allow** for a site and
app, or turn on **Allow All Without Asking**, which also needs Touch ID.
Sign-in links have their own switch, off until you turn it on. Only mail from
the site's own domain counts. Nothing goes over the network. `codecatch --help`
has the rest.

## Privacy

Codes and messages stay on your Mac. Received codes live in memory only. Mail
passwords and Bitwarden secrets live in your login Keychain (service
`com.uros.codecatch`). CodeCatch connects only to your mail provider, Bitwarden
when you import, `codecatch.app` for updates, and Google's logo service (turn
off in Settings → Privacy).

The full list is at [codecatch.app/privacy](https://codecatch.app/privacy/).
How it works inside is in [ARCHITECTURE.md](ARCHITECTURE.md).

## Alternatives

Looking for a 2FHey or MessAuto alternative that also reads mail, catches
sign-in links (magic links) and works in Chrome, Arc and Firefox? See [CodeCatch vs 2FHey](https://codecatch.app/vs/2fhey/) and
[CodeCatch vs MessAuto](https://codecatch.app/vs/messauto/).

## Develop

See [CONTRIBUTING.md](CONTRIBUTING.md). Run the tests with `scripts/test.sh`.

## License

[GPL-3.0](LICENSE). If you share a fork or a build, you must publish its source
under the same license. To report a security problem, see [SECURITY.md](SECURITY.md).

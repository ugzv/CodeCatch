# Security

CodeCatch reads verification codes, so a flaw in it matters. Please report one
privately rather than in a public issue: open the repository's **Security** tab
and choose **Report a vulnerability**.

Useful in a report: the CodeCatch build (Get Info shows it), the macOS version,
and the steps or a sample message that show the problem. Remove real codes,
links and addresses from anything you attach.

In scope: anything that exposes a code, sign-in link, message, mail credential or
Bitwarden secret to another app, another user, the network or the disk; a way to
make CodeCatch open, type or send something the user did not ask for; a way to
get a code or link through `codecatch` without the user's approval or a rule they
made; and flaws in the update path. What CodeCatch reads, keeps and connects to is listed at
<https://codecatch.app/privacy/>; behaviour that contradicts that page is a bug
worth reporting too.

Only the latest release is supported. It updates itself.

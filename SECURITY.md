# Security policy

## Reporting a vulnerability

Please report security problems privately, not in a public issue: on GitHub, open the repository's
**Security** tab and click **Report a vulnerability**. Include what you found, the Manimble version
(*Manimble ▸ About Manimble*), and how to reproduce it. We'll reply as soon as we can and tell you what we
plan to do about it.

If private reporting isn't available, open an issue that says you have a security report and asks for a
private contact, without the details.

## Supported versions

Fixes go into the newest release only. The current release is always at
<https://github.com/pachterlab/Manimble/releases/latest>.

## What Manimble does to stay safe

- Releases are built by GitHub Actions from a tagged commit, signed with an Apple Developer ID and notarized
  by Apple. Each release lists the SHA-256 of every file in `SHA256SUMS`.
- The Python runtime and TinyTeX that first-launch setup downloads are checked against a SHA-256 before they
  are unpacked: the runtime's is built into the app, TinyTeX's is the one GitHub recorded for the release file.
- API keys for cloud voices are kept in the macOS keychain, never in a deck.
- Manimble has no accounts, analytics or telemetry. What it sends over the network, and when, is listed in
  [Privacy and network use](https://pachterlab.github.io/Manimble/reference/privacy/).

A slide is Python code, and Manimble runs it to render the slide. Open decks only from people you trust, as
you would any other script.

# Security Policy

## Supported version

Security fixes are provided for the newest published AeriVoice beta only.

## Report a vulnerability privately

Use [GitHub's private vulnerability reporting form](https://github.com/DanielOu1208/aerivoice/security/advisories/new).
Do not open a public issue for a suspected vulnerability.

Include the affected version, macOS version, reproduction steps, and expected
impact. Remove API keys, transcript contents, clipboard data, and other personal
information from screenshots and logs.

If private vulnerability reporting is temporarily unavailable, open a public
issue containing no vulnerability details and ask the maintainer to establish a
private channel.

## Security boundaries

AeriVoice stores provider keys in Keychain and ships with the hardened runtime.
It is not sandboxed, and it requests Microphone and Accessibility access to
perform system-wide dictation and text insertion. Audio and transcript data are
processed by the providers described in [PRIVACY.md](PRIVACY.md).

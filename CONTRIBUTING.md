# Contributing to AeriVoice

Thanks for helping improve AeriVoice.

## Issues are welcome

Use a GitHub issue for reproducible bugs or focused feature requests. Search
existing issues first and keep each issue to one problem.

For bugs, include the AeriVoice version, macOS version, Mac model, audio-device
route, expected behavior, and concise reproduction steps. Never include API
keys, transcript contents, clipboard data, or unredacted provider responses.

Security problems must follow [SECURITY.md](SECURITY.md), not the public issue
tracker.

## Pull requests

The project is not currently accepting unsolicited pull requests. Maintainer
changes still use pull requests and required CI so `main` stays reviewable.

## Local verification

The project requires Xcode 26.4.1 or newer and macOS 26. Run the complete test
suite before reporting a source-level regression:

```sh
xcodebuild \
  -project AeriVoice.xcodeproj \
  -scheme AeriVoice \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  test
```

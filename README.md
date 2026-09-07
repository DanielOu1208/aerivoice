# AeriVoice

<p align="center">
  <img src="docs/images/aerivoice-icon.png" alt="AeriVoice app icon" width="104" height="104">
</p>

<p align="center">
  <strong>Speak naturally. Write clearly. Anywhere on your Mac.</strong>
</p>

<p align="center">
  <a href="https://github.com/DanielOu1208/aerivoice/releases/latest">Download</a> ·
  <a href="#getting-started">Getting started</a> ·
  <a href="#providers-and-models">Providers</a> ·
  <a href="#privacy-and-security">Privacy</a>
</p>

<p align="center">
  <a href="https://github.com/DanielOu1208/aerivoice/releases/latest"><img src="https://img.shields.io/github/v/release/DanielOu1208/aerivoice?include_prereleases&amp;style=flat&amp;label=release" alt="Latest release (including beta)"></a>
  <a href="https://github.com/DanielOu1208/aerivoice/releases"><img src="https://img.shields.io/github/downloads/DanielOu1208/aerivoice/total?style=flat" alt="GitHub release downloads"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue?style=flat" alt="MIT license"></a>
  <a href="#getting-started"><img src="https://img.shields.io/badge/macOS-26%2B-555?style=flat" alt="macOS 26 or newer"></a>
  <a href="#getting-started"><img src="https://img.shields.io/badge/Apple_Silicon-555?style=flat" alt="Apple Silicon"></a>
</p>

---

AeriVoice is a native macOS menu-bar dictation app that turns your speech into
clean text in the app you're using. See your words appear live, refine them with
AI, and keep writing without switching windows.

## Why AeriVoice?

- **Fast transcription. Fast cleanup.** Pair Soniox's live transcription with
  Cerebras-powered AI cleanup for ready-to-use text with minimal waiting.
- **Choose your providers and models.** Pick from supported transcription and
  cleanup options to tune your setup around speed, quality, and cost.
- **Your words, your style.** Keep edits light with Faithful mode, or choose
  Polished mode for more refined writing.
- **Stay in your flow.** Tap or hold a global shortcut, follow the live transcript
  in a compact notch-style overlay, and send the finished text to your current app.
- **Make it personal.** Add vocabulary hints for names and specialist terms,
  enable sound cues, and launch AeriVoice at login.
- **At home on your Mac.** A native menu-bar experience, API keys stored in macOS
  Keychain, and no AeriVoice account required.

## Speed that keeps up

**~500 ms median from finishing dictation to sending cleaned text to your app
with Soniox + Cerebras.**

Based on median timings in recent local testing. Performance varies by network,
model, and provider load. See the [benchmark details](docs/CLEANUP-PERFORMANCE.md#readme-performance-checkpoint-2026-09-07)
for measurements and methodology.

AeriVoice sends text using Paste in native apps, browsers, Electron apps, and
terminals. The result also stays on your clipboard. If the target is detected as
secure, unavailable, read-only, or changed, AeriVoice copies the result and tells
you why it couldn't paste. A green check mark means Paste was sent; it does not
confirm the destination app accepted the text.

## Providers and models

Choose transcription and cleanup separately in Settings, using your own API keys.

| Stage | Provider | Supported models |
| --- | --- | --- |
| Live transcription | Soniox — default | Soniox Realtime |
| Live transcription | Meta — optional | Muse Voice Transcribe 1.0 |
| AI cleanup | OpenRouter — default | Gemini 3.5 Flash Lite, Gemini 3.7 Flash, GPT-5.6 Luna · Fast, GPT-OSS 120B · Cerebras |
| AI cleanup | Cerebras — experimental direct connection | Qwen 3.8 27B |
| AI cleanup | Groq — experimental direct connection | Qwen 3.8 27B |

New installs use Soniox and Gemini 3.5 Flash Lite through OpenRouter, with Minimal
reasoning. You can switch cleanup models and adjust reasoning effort where
supported. To try the Soniox + Cerebras pairing above, select Cerebras for cleanup
and Qwen 3.8 27B with reasoning set to None.

## Getting started

AeriVoice is currently in **beta**. You'll need an **Apple Silicon Mac running
macOS 26 or newer**, plus your own provider accounts. Provider charges and usage
limits may apply.

### Install the beta

1. Download `AeriVoice-v0.1.0-beta.5-arm64.dmg` and its `.sha256` file from
   [GitHub Releases](https://github.com/DanielOu1208/aerivoice/releases).
2. From the download directory, verify the artifact:

   ```sh
   shasum -a 256 -c AeriVoice-v0.1.0-beta.5-arm64.dmg.sha256
   ```

3. Open the DMG and drag AeriVoice to Applications.
4. Launch AeriVoice and follow onboarding to add your provider keys and grant
   **Microphone** and **Accessibility** permission.

For the default setup, get a [Soniox API key](https://console.soniox.com/) and an
[OpenRouter API key](https://openrouter.ai/settings/keys). Alternatively, use a
[Meta Model API key](https://dev.meta.ai/docs/speech-to-text) for transcription,
or configure direct Cerebras or Groq cleanup in Settings.

Once setup is complete, use your configured shortcut to dictate into a text field.

AeriVoice does not include an automatic updater. Check GitHub Releases for new
versions.

## Privacy and security

AeriVoice has no account system or first-party server. It uses cloud providers
for transcription and cleanup:

- Microphone audio and vocabulary hints are sent to your selected transcription
  provider: Soniox or Meta. Meta sessions request zero data retention.
- The completed transcript is sent to OpenRouter, Groq, or Cerebras when cleanup
  is used.
- API keys are stored in the macOS Keychain.
- Latency diagnostics stay on your Mac for 90 days and exclude transcript text,
  vocabulary, credentials, clipboard contents, provider bodies, and raw errors.

Read [PRIVACY.md](PRIVACY.md) for details. Report vulnerabilities privately as
described in [SECURITY.md](SECURITY.md); never put credentials or private
transcript text in a public issue.

## Build from source

<details>
<summary>Build and run tests with Xcode</summary>

You need Xcode 26.4.1 or newer with the macOS 26 SDK.

```sh
git clone https://github.com/DanielOu1208/aerivoice.git
cd aerivoice
open AeriVoice.xcodeproj
```

Choose your own development team in Xcode if signing is required, then run the
`AeriVoice` scheme. CI builds without code signing.

To run the complete test suite from Terminal:

```sh
xcodebuild \
  -project AeriVoice.xcodeproj \
  -scheme AeriVoice \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  test
```

</details>

## Support and participation

[Open an issue](https://github.com/DanielOu1208/aerivoice/issues) for a bug or
focused feature request. The project is not currently accepting unsolicited
pull requests; see [CONTRIBUTING.md](CONTRIBUTING.md).

## License

Source code and repository artwork are available under the [MIT License](LICENSE).

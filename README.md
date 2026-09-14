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

<p align="center">
  <img src="docs/images/aerivoice-demo.gif" alt="Silent looping demo: AeriVoice transcribes speech live, cleans it up, and pastes the result into a terminal" width="800">
</p>

## Why AeriVoice?

- **Fast transcription. Fast cleanup.** Pair Soniox's live transcription with
  Cerebras-powered AI cleanup for ready-to-use text with minimal waiting.
- **Choose your providers and models.** Pick from supported transcription and
  cleanup options to tune your setup around speed, quality, and cost.
- **Your words, your style.** Polished mode refines your writing by default.
  Choose Faithful mode for lighter edits; existing style choices are preserved.
- **Stay in your flow.** Tap or hold a global shortcut, follow the live transcript
  in a compact notch-style overlay, and send the finished text to your current app.
- **Make it personal.** Add vocabulary hints for names and specialist terms,
  enable sound cues, and launch AeriVoice at login.
- **At home on your Mac.** A native menu-bar experience, API keys stored in macOS
  Keychain, and no AeriVoice account required.

## Speed that keeps up

**~500 ms median from finishing dictation to sending cleaned text to your app
with Soniox + Cerebras.**

[Local benchmark details](docs/CLEANUP-PERFORMANCE.md#readme-performance-checkpoint-2026-09-07).
Timings vary by network, model, and provider load.

If Paste is unavailable, AeriVoice can copy the result for you.
[How Paste works](docs/TEXT-INSERTION.md#clipboard-and-result-reporting).

## Providers and models

Choose transcription and cleanup separately in Settings. Cloud providers use your own API keys; Offline mode needs none.

| Stage | Provider | Supported models |
| --- | --- | --- |
| Live transcription | <img src="docs/images/providers/soniox.png" width="24" height="24" alt=""> **Soniox** — Default | Soniox Realtime |
| Live transcription | <img src="docs/images/providers/meta.svg" width="24" height="24" alt=""> **Meta** | Muse Voice Transcribe 1.0 |
| Live transcription | **Local** | Apple Speech (system-managed language support) or NVIDIA Nemotron 3.5 (English) — Recommended |
| AI cleanup | <img src="docs/images/providers/openrouter.svg" width="24" height="24" alt=""> **OpenRouter** — Default | Gemini 3.5 Flash Lite, Gemini 3.7 Flash, GPT-5.6 Luna · Fast, GPT-OSS 120B · Cerebras, plus a searchable catalog of compatible text models |
| AI cleanup | <img src="docs/images/providers/cerebras.svg" width="24" height="24" alt=""> **Cerebras** | Qwen 3.8 27B |
| AI cleanup | <img src="docs/images/providers/groq.svg" width="24" height="24" alt=""> **Groq** — Experimental | Qwen 3.8 27B |

**Default:** Soniox + Gemini 3.5 Flash Lite via OpenRouter, with Minimal reasoning.

**Speed setup:** Soniox + Qwen 3.8 27B via direct Cerebras, with reasoning set to None.

Switch providers, models, and reasoning effort in Settings. Under **AI Cleanup →
Provider → Model**, OpenRouter shows recommended presets first. **All compatible
models** opens a searchable catalog, excluding media-generation models, automatic
routers, and known safety classifiers. You can also enter a text model ID manually.

The Provider section also exposes reasoning levels from OpenRouter’s catalog,
including newly advertised levels without an app update. “Model default” leaves
reasoning settings to the provider. Models with mandatory reasoning do not offer
“None”; models without advertised effort levels offer only the model default.
Recommended presets keep their initial defaults and provider routing, using their
built-in reasoning choices only when catalog metadata is unavailable.

Models and reasoning metadata are cached on disk, refreshed when cleanup settings
or the picker open after 24 hours, and can be refreshed manually. Failed refreshes
keep the last successful cache. Choices are saved separately per provider and
model; an unavailable saved level temporarily falls back to the model default.

Additional models use plain-text cleanup and the provider’s output limit. Speed,
cost, and cleanup quality vary; the ten-second cleanup deadline still applies.
Zero data retention is required by default for these models and can be changed in
the Provider section.

## Getting started

AeriVoice is currently in **beta**. You'll need an **Apple Silicon Mac running
macOS 26 or newer**. Cloud transcription and cleanup use your own provider
accounts; Offline mode needs no API keys. Provider charges and usage limits may apply.

1. **Install.** [Download the beta](https://github.com/DanielOu1208/aerivoice/releases/latest), open the DMG, and drag AeriVoice to Applications.
2. **Set up.** Connect your cloud providers, or choose a local model and enable Offline mode to skip cloud cleanup and API keys. Apple Speech reuses installed language support or offers a download; Nemotron requires its own download. Grant Microphone and Accessibility permission.
3. **Dictate.** Focus a text field and tap or hold your configured shortcut.

For the default setup: [Soniox API key](https://console.soniox.com/) +
[OpenRouter API key](https://openrouter.ai/settings/keys). Other providers are
available in Settings.

<details>
<summary>Verify your download</summary>

Download `AeriVoice-v0.1.0-beta.8-arm64.dmg` and its `.sha256` file from
[GitHub Releases](https://github.com/DanielOu1208/aerivoice/releases), then run
this in your download directory before opening the DMG:

```sh
shasum -a 256 -c AeriVoice-v0.1.0-beta.8-arm64.dmg.sha256
```

</details>

Updates are manual—check GitHub Releases for new versions.

## Privacy and security

- **Cloud processing:** audio and vocabulary go to your transcription provider;
  transcripts go to your cleanup provider. No AeriVoice account or first-party server.
- **Keychain storage:** API keys stay in macOS Keychain and authenticate requests
  to your chosen providers.
- **Local diagnostics:** optional diagnostics are off by default. When enabled,
  records stay on your Mac for up to 365 days within a 200 MB limit, without
  transcript text, audio, or credentials.

[Privacy details](PRIVACY.md) · [Report a security issue privately](SECURITY.md)

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

Source code and original AeriVoice artwork use the [MIT License](LICENSE).
Provider logos belong to their respective owners; see [artwork credits](docs/ARTWORK.md).

## Local transcription

AeriVoice also supports downloadable, on-device English transcription with Nemotron 3.5 and the existing Dictionary. See [Local dictation](docs/LOCAL-DICTATION.md) for setup, model requirements, privacy boundaries, and validation.

Local transcription accuracy may be lower than cloud models. [Local setup, Offline mode, and shortcut behavior](docs/LOCAL-DICTATION.md) describes model downloads and the Hybrid, Toggle, and Hold modes.

# AeriVoice

<p align="center">
  <img src="docs/images/aerivoice-icon.png" alt="AeriVoice faceted microphone app icon" width="104" height="104">
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
- **Choose your providers and models.** Pick from cloud or on-device transcription
  and cloud cleanup options to tune your setup around speed, quality, and cost.
- **Dictate offline when you need to.** Apple Speech or a downloaded Nemotron model
  transcribes on your Mac; Offline mode inserts the result with no AI cleanup and
  no cloud keys.
- **Your words, your style.** Polished mode refines your writing by default.
  Choose Faithful for lighter edits, or Compose for lists, paragraphs, and spoken corrections; existing style choices are preserved.
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
| Live transcription | <img src="docs/images/providers/spacex.png" width="24" height="24" alt=""> **Grok (xAI)** — Development | Grok Voice Transcribe 2.0 |
| Live transcription | **Local** — On-device | **NVIDIA Nemotron 3.5** (English, ~611 MB) — Recommended, or **Apple Speech** (system-managed languages) |
| AI cleanup | <img src="docs/images/providers/openrouter.svg" width="24" height="24" alt=""> **OpenRouter** — Default | Gemini 3.5 Flash Lite, Gemini 3.7 Flash, GPT-5.6 Luna · Fast, GPT-OSS 120B · Cerebras, plus a searchable catalog of compatible text models |
| AI cleanup | <img src="docs/images/providers/cerebras.svg" width="24" height="24" alt=""> **Cerebras** | Qwen 3.8 27B |
| AI cleanup | <img src="docs/images/providers/groq.svg" width="24" height="24" alt=""> **Groq** — Experimental | Qwen 3.8 27B |

AI cleanup runs in the cloud; Offline mode skips it.

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

### Grok transcription

Available starting in beta.10.

Choose **Grok** under Dictation and connect an xAI API key with API credits.
AeriVoice uses Grok Voice Transcribe 2.0 for live transcription. The existing
Dictionary supplies up to 100 recognition hints of 50 Unicode code points each;
excluded entries remain saved and are listed in Dictation settings. Recognition
hints do not guarantee exact spelling. Chinese and mixed-language quality require
evaluation; do not assume language support from the presence of the provider.

AeriVoice can reuse a prepared connection for up to 30 seconds after it becomes
ready. Buffered audio catches up at up to 1.35× real time before returning to
normal pacing; the audio samples are sent unchanged.

See [Grok validation](docs/GROK-VALIDATION.md) for test and benchmark status.

## Local and offline dictation

Choose **Local** in Dictation settings to transcribe on your Mac:

| Engine | Notes |
| --- | --- |
| **NVIDIA Nemotron 3.5** — Recommended | English, via FluidAudio and Core ML. ~611 MB download; uses the Dictionary as recognition hints. |
| **Apple Speech** | macOS 26 SpeechAnalyzer. Reuses installed language support; a missing language needs an Apple-managed download. |

**Providers → Local models → Manage** owns downloads, language setup, status, and
removal; interrupted Nemotron downloads can be resumed or removed. Selecting a
local model does not disable cloud cleanup on its own — outside Offline mode, your
cleanup provider still receives the transcript.

**Offline mode** (General, the menu bar, or local onboarding) uses the selected
on-device engine, skips AI cleanup, and needs no cloud keys. It blocks new
AeriVoice-initiated network requests, is remembered across launches, and preserves
your provider choices for when you switch back. Local never falls back to a cloud
engine when assets are unavailable.

Local accuracy may be lower than cloud models. [Local dictation](docs/LOCAL-DICTATION.md)
covers model requirements, shortcuts, privacy, and validation.

## Cleanup styles

Choose a style under **AI Cleanup → Cleanup style**. Open the style chooser to see a short description of every option:

| Style | What it does |
| --- | --- |
| **Faithful** | Removes speech clutter and fixes punctuation while staying close to your wording. |
| **Polished** (default) | Improves grammar and phrasing without losing your meaning or details. |
| **Compose (Experimental)** | Organizes clear lists and paragraphs, resolves spoken corrections, and refines the writing. |
| **Custom (Experimental)** | Starts with Polished cleanup and applies your own instructions. |

Compose edits the current recording and inserts the finished text when you stop.
For example, “Meet on Monday, sorry, Wednesday” keeps Wednesday; “first save the
file, second close the window” becomes a numbered list. “New line” and “new
paragraph” control spacing when used as layout cues. Quoted or discussed cues
stay literal, and requests you dictate to another person or AI remain requests.
Lists use plain-text bullets or numbers; rich text and editing earlier recordings
are not supported. Language, script, and mixed-language speech are preserved
unless your custom settings request a change.

Compose uses your selected cleanup model. Output quality and timing vary by
model; the initial evaluation used direct Cerebras with reasoning disabled.
Compose is experimental: it can miss formatting or corrections, or change meaning.
For more reliable results, we recommend trying higher reasoning when supported;
this adds latency, and the reliability improvement has not yet been verified in
our benchmarks. Review important text. Your reasoning setting is not changed
automatically. Offline mode skips all cleanup.
See the [Compose benchmark checkpoint](docs/COMPOSE-VALIDATION.md) for measured
results, evaluation limits, and remaining UI acceptance gates.

## Usage stats

Open **Settings → Stats** for words dictated, average dictation WPM, completed
sessions, and recording time. Choose 7 days, 30 days, or all time to see usage trends.
Counts use final output after cleanup, including text copied to the clipboard.
Average WPM divides total output words by total recording minutes, including pauses
but excluding processing delay. Cleanup and language affect the count; word rates
are not directly comparable across languages.

Stats start with this version, stay on this Mac, and do not retain audio or transcript
history. Manage collection or clear totals under **Privacy & Data → Usage stats**.
Disabling collection preserves saved totals. Time-saved estimates are not included.

## Custom cleanup instructions (Experimental)

Under **AI Cleanup → Cleanup style**, choose **Custom** to reveal the instructions
editor. Add instructions for tone, spelling, terminology, translation, or formatting
on top of Polished cleanup. Instructions apply only while Custom is selected;
switching to Faithful, Polished, or Compose hides the editor and keeps your text
saved for later. Leave the field empty, or choose **Clear**, to use Polished cleanup.
Custom instructions carry the same experimental warning and higher-reasoning
guidance as Compose.

Instructions are saved locally and sent to your selected cleanup provider with
each dictation in Custom. They are not included in routine diagnostic logs. The
limit is 2,000 characters; over-limit edits remain visible but are not saved. Changes made
while recording apply to the next dictation. Offline mode disables AI cleanup
and these controls.

## Getting started

AeriVoice is currently in **beta**. You'll need an **Apple Silicon Mac running
macOS 26 or newer**. Cloud transcription and cleanup use your own provider
accounts; Offline mode needs no API keys. Provider charges and usage limits may apply.

1. **Install.** [Download the beta](https://github.com/DanielOu1208/aerivoice/releases/latest), open the DMG, and drag AeriVoice to Applications.
2. **Set up.** Connect your cloud providers, or choose a local model and enable Offline mode to skip cloud cleanup and API keys. Apple Speech reuses installed language support; Nemotron needs a ~611 MB download. Manage either under **Providers → Local models**. Grant Microphone and Accessibility permission.
3. **Dictate.** Focus a text field and use your shortcut — Hybrid by default: tap to toggle, or hold and release to finish. Toggle and Hold modes, plus exact left/right Command and Option keys, are in Settings.

For the default setup: [Soniox API key](https://console.soniox.com/) +
[OpenRouter API key](https://openrouter.ai/settings/keys). Other providers are
available in Settings.

<details>
<summary>Verify your download</summary>

Download `AeriVoice-v0.1.0-beta.10-arm64.dmg` and its `.sha256` file from
[GitHub Releases](https://github.com/DanielOu1208/aerivoice/releases), then run
this in your download directory before opening the DMG:

```sh
shasum -a 256 -c AeriVoice-v0.1.0-beta.10-arm64.dmg.sha256
```

</details>

AeriVoice checks for signed updates automatically and asks before downloading or
installing them. Use **Check for Updates…** to check manually; automatic checks
can be disabled in Settings. Offline mode pauses update checks and downloads.
The public update track includes beta releases. Versions without the built-in
updater need one final manual installation from GitHub Releases.

## Privacy and security

- **Cloud processing:** audio and vocabulary go to your transcription provider;
  transcripts go to your cleanup provider. No AeriVoice account or first-party server.
- **On-device option:** Apple Speech or downloaded Nemotron weights transcribe on
  your Mac; Offline mode skips cleanup and blocks new AeriVoice-initiated network
  requests. Downloads connect to Apple or Hugging Face.
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
The SpaceX mark is sourced from its official favicon; see
[provider asset attribution](AeriVoice/ProviderIcons-LICENSE.txt).

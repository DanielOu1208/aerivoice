# Providers and models

Choose transcription and cleanup separately in Settings. Cloud providers use your own API keys; Offline mode needs none. AI cleanup runs in the cloud; Offline mode skips it.

| Stage | Provider | Models |
| --- | --- | --- |
| Live transcription | **Soniox** (default) | Soniox Realtime |
| Live transcription | **Grok (xAI)** | Grok Voice Transcribe 2.0 |
| Live transcription | **Meta** | Muse Voice Transcribe 1.0 |
| Live transcription | **Local** (on-device) | NVIDIA Nemotron 3.5 (English, ~611 MB, recommended) or Apple Speech |
| AI cleanup | **OpenRouter** (default) | Gemini 3.5 Flash Lite, Gemini 3.7 Flash, GPT-5.6 Luna · Fast, GPT-OSS 120B · Cerebras, plus a searchable catalog |
| AI cleanup | **Cerebras** | Qwen 3.8 27B |
| AI cleanup | **Groq** (experimental) | Qwen 3.8 27B |

**Default:** Soniox + Gemini 3.5 Flash Lite via OpenRouter, Minimal reasoning.
**Speed setup:** Soniox + Qwen 3.8 27B via direct Cerebras, reasoning None.

For on-device transcription and Offline mode, see [Local dictation](LOCAL-DICTATION.md).

## OpenRouter catalog

Under **AI Cleanup → Provider → Model**, OpenRouter shows recommended presets first. **All compatible models** opens a searchable catalog that excludes media-generation models, automatic routers, and known safety classifiers. You can also enter a text model ID manually.

- Models OpenRouter has retired are hidden; retiring models are labeled, and Settings warns if the selected model is retiring.
- Catalog models use plain-text cleanup and the provider's output limit. Speed, cost, and quality vary; the ten-second cleanup deadline still applies.
- Zero data retention is required by default for catalog models and can be changed in the Provider section.

## Reasoning levels

The Provider section shows reasoning levels from OpenRouter's catalog, including newly advertised levels without an app update. "Model default" leaves reasoning to the provider. Models with mandatory reasoning do not offer "None"; models without advertised levels offer only the default. Recommended presets keep their built-in routing and default reasoning, and use their own choices when catalog metadata is unavailable.

Models and reasoning metadata are cached on disk, refreshed after 24 hours when cleanup settings or the picker open, and can be refreshed manually. A failed refresh keeps the last successful cache. Choices are saved per provider and model; an unavailable saved level temporarily falls back to the model default.

## Grok

Choose **Grok** under Dictation and connect an xAI API key with API credits. The Dictionary supplies up to 100 recognition hints of up to 50 characters each; excluded entries stay saved and are listed in Dictation settings. Hints do not guarantee exact spelling, and mixed-language quality varies.

AeriVoice keeps a prepared Grok connection ready for up to five minutes (replaced automatically while you are using the app), so most dictations skip connection setup. No audio is sent during preparation. Buffered audio catches up at up to 1.35× real time with unchanged samples. See [Grok validation](GROK-VALIDATION.md).

## Connections

Groq, OpenRouter, and Cerebras cleanup connections are prepared when dictation starts, so the cleanup request after you stop usually reuses an open connection. Transcription connections open when you press the shortcut, overlapping the start cue and microphone startup.

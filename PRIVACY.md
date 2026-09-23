# AeriVoice Privacy

This document describes the current AeriVoice data flow. AeriVoice does not
operate an account system, analytics service, or first-party backend. It does
use third-party transcription and AI providers selected by the user.

## Data sent to providers

### Soniox

While dictation is active, AeriVoice sends microphone audio to Soniox as a
realtime 16 kHz mono PCM stream. The Soniox API key, a random session reference,
and any vocabulary hints configured in AeriVoice are sent with the stream.
Soniox returns partial and final transcript tokens.

### Meta Model API

When Meta is selected for transcription, AeriVoice sends microphone audio as a
realtime 16 kHz mono PCM stream to Meta's Model API. The Meta Model API key, a
random session reference, and any vocabulary hints configured in AeriVoice are
sent with the stream. Meta's `muse-voice-transcribe-1.0` model returns
cumulative partial transcripts and a final transcript.

AeriVoice sets Meta's zero-data-retention override for every session. Meta's
current account controls, enforcement, abuse monitoring, and terms remain
controlled by Meta; review them before enabling this provider.

### xAI (Grok)

When Grok is selected, AeriVoice streams microphone audio as 16 kHz mono PCM
to xAI's `grok-voice-transcribe-2.0` model. Your xAI API key is sent in the
Authorization header. Up to 100 eligible dictionary terms are sent as URL
query parameters to help recognition; terms longer than 50 Unicode code points
are excluded. The Dictionary displays exclusions without deleting saved terms.
When Grok is selected and the app is awake and unlocked, AeriVoice may prepare
one authenticated connection for up to 30 seconds after launch, wake, selection,
configuration changes, or successful dictation. This sends the key and eligible
dictionary terms before dictation, but no microphone audio or synthetic silence.
The unused connection expires without a background reconnect loop and is
discarded on lock, sleep, Offline mode, cancellation, or relevant settings changes.
Keys, request URLs, and provider response bodies are not written to AeriVoice
diagnostics. xAI's current retention and account policies apply; AeriVoice does
not request or claim a zero-data-retention guarantee for this provider.

### OpenRouter, Groq, or Cerebras

After the selected transcription provider finalizes a transcript, AeriVoice
sends that transcript to the selected cleanup provider. The request includes
the selected model, reasoning level, cleanup instructions, and the provider API
key.

OpenRouter can route requests to an underlying model provider. AeriVoice asks
OpenRouter for zero-data-retention routing for its Gemini and GPT-OSS choices,
but provider behavior and terms remain controlled by OpenRouter and the
underlying provider. Additional OpenRouter catalog models also require zero data
retention by default. Users can disable that requirement in AI Cleanup settings;
when disabled, the provider may retain transcript inputs and cleaned outputs.
Opening cleanup settings or the model picker refreshes OpenRouter’s public model
and reasoning catalog when the saved copy is older than 24 hours. Manual refresh
is also available. These requests include no API key, audio, or transcript. Direct Groq and Cerebras cleanups
send requests directly to their respective API endpoints; review their current
data controls before enabling them. Groq cleanup is experimental.

When Cerebras is selected, AeriVoice may also send an authenticated connection
warm-up request when dictation starts. That request contains no audio or
transcript text and is limited to at most one attempt per minute.

Provider pricing, retention, abuse monitoring, and privacy terms can change.
Review the current Soniox, Meta, xAI, OpenRouter, Groq, and Cerebras policies for your accounts.

## Data stored on the Mac

- Provider API keys are stored in the macOS Keychain under the AeriVoice bundle
  identifier.
- App preferences, including selected providers, models, and reasoning levels, are
  stored with macOS preferences.
- OpenRouter’s public model names, capabilities, reasoning options, and last
  successful refresh time are cached in
  `~/Library/Caches/com.danielou.AeriVoice/openrouter-catalog-v1.json`. This cache
  contains no credentials or dictation content and remains usable while offline.
- Insertion uses the normal Paste shortcut. With **Restore clipboard after dictation**
  enabled (the default), AeriVoice temporarily holds an in-memory clipboard backup
  and checks the destination's text and selection through Accessibility. It restores
  the backup only after verifying the exact expected edit in the same field and
  confirming the clipboard is still unchanged. If backup or verification is unavailable,
  the dictation stays on the clipboard. These contents are never written to diagnostics.
  The green check mark means the Paste shortcut was sent; it does not itself confirm
  delivery or restoration. Detected secure fields and secure keyboard-input mode copy with a warning
  instead of receiving an automatic Paste. Copies you make after dictation stops
  are preserved; if the clipboard changed, the transcript is not copied over it.
- Usage stats are enabled by default and stored only on this Mac in
  `~/Library/Application Support/AeriVoice/UsageStats/totals-v1.json`. They contain
  daily aggregate final-output word counts, completed dictation counts, and recording
  durations. Language-aware word counting happens in memory; no audio, transcript,
  provider history, or destination-app details are saved in stats. Pasted and
  clipboard-only output count once; cancelled, failed, and empty sessions do not.
  Collection starts with this version and does not import old diagnostics.
  **Privacy & Data → Collect usage stats** pauses collection without deleting totals.
  **Clear Stats…** removes all usage totals, including pending contributions from an
  active dictation. Daily totals remain until cleared and are never uploaded.
- Optional performance diagnostics are disabled by default. When enabled, they are stored in
  `~/Library/Application Support/AeriVoice/Benchmarks` with user-only file
  permissions.

Diagnostics include timings, workload sizes, provider routing metadata, HTTP
status, and coarse outcomes. Runtime records add initialization and activity
events, CPU time, memory footprint, disk and wakeup counters, thermal/power
state, build identity, machine model and memory, selected settings, and coarse
audio transport/format. Resource samples run at activity boundaries and about
every five minutes while idle. They do not start microphone capture.

Records do not include transcript text, vocabulary, API keys, clipboard contents,
provider response bodies, raw errors, computer names, serial numbers, microphone
names, or destination-app contents. Completed diagnostics are retained for up to
365 days within a 200 MB limit; older completed segments are removed first.
Disabling logging stops collection and discards the active recovery checkpoint.
Existing completed history remains until cleared or expired.

## Permissions

- **Microphone:** captures audio only while an AeriVoice dictation is active.
- **Accessibility:** observes the active target and inserts completed text.

AeriVoice uses the hardened runtime but is not sandboxed because it performs
system-wide shortcut and Accessibility-assisted insertion.

## Control and deletion

- Disable performance logging under **Settings → Privacy & Data**.
- Use **Clear Completed History** on that page to remove completed interaction
  and runtime records and archives, or reveal the data folder and remove it manually while AeriVoice is
  not running.
- Remove or replace provider keys under **Settings → Providers**.
- Revoke Microphone or Accessibility access in macOS System Settings.
- Uninstall AeriVoice by quitting it and moving the app from Applications to
  Trash. Remove its preferences, Keychain entries, and Application Support data
  separately if you want a complete local reset.

AeriVoice does not upload its own crash reports. macOS or third-party providers
may collect diagnostics under their own settings and policies.

## Local transcription

When Local is selected, Apple Speech or downloaded NVIDIA Nemotron models transcribe audio on your Mac without a transcription account or API key. An explicit Nemotron model download connects to Hugging Face. Apple Speech uses system-managed language assets; if missing, an explicit setup download connects to Apple. Dictionary hints are processed locally. Existing cleanup settings still apply and may send the transcript to your selected cloud cleanup provider. Local does not automatically send audio to a cloud transcription provider on failure.

### Offline mode

Offline mode uses the selected local transcription engine and bypasses AI cleanup, so neither audio nor transcripts are sent to cloud providers. It also blocks new AeriVoice-initiated background connections, model catalog requests, credential validation, and downloads. Existing app requests are cancelled when entering the mode. The mode is remembered across launches, preserves normal provider settings, and never falls back to a cloud engine when local assets are unavailable. macOS controls shared Apple speech assets and may continue system updates or automatically retry an Apple language download requested before Offline mode was enabled.

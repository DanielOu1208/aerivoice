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

### OpenRouter, Groq, or Cerebras

After the selected transcription provider finalizes a transcript, AeriVoice
sends that transcript to the selected cleanup provider. The request includes
the selected model, reasoning level, cleanup instructions, and the provider API
key.

OpenRouter can route requests to an underlying model provider. AeriVoice asks
OpenRouter for zero-data-retention routing for its Gemini and GPT-OSS choices,
but provider behavior and terms remain controlled by OpenRouter and the
underlying provider. Direct Groq and Cerebras cleanups are experimental and
send requests directly to their respective API endpoints; review their current
data controls before enabling them.

Provider pricing, retention, abuse monitoring, and privacy terms can change.
Review the current Soniox, Meta, OpenRouter, Groq, and Cerebras policies for your accounts.

## Data stored on the Mac

- Provider API keys are stored in the macOS Keychain under the AeriVoice bundle
  identifier.
- App preferences, including selected providers and models, are stored with
  macOS preferences.
- When text insertion uses Paste, the transcript is placed on the clipboard
  temporarily. AeriVoice restores the previous clipboard only when it can prove
  that it still owns the temporary clipboard contents.
- Optional latency diagnostics are enabled by default and stored in
  `~/Library/Application Support/AeriVoice/Benchmarks` with user-only file
  permissions.

Latency records include timings, workload sizes, provider routing metadata,
HTTP status, and coarse outcomes. They do not include transcript text,
vocabulary, API keys, clipboard contents, provider response bodies, or raw
errors. Completed records are pruned after 90 days.

## Permissions

- **Microphone:** captures audio only while an AeriVoice dictation is active.
- **Accessibility:** observes the active target and inserts completed text.

AeriVoice uses the hardened runtime but is not sandboxed because it performs
system-wide shortcut and Accessibility-assisted insertion.

## Control and deletion

- Disable latency logging under **Settings → Privacy & Data**.
- Use **Clear Completed History** on that page to remove completed latency
  records, or reveal the data folder and remove it manually while AeriVoice is
  not running.
- Remove or replace provider keys under **Settings → Providers**.
- Revoke Microphone or Accessibility access in macOS System Settings.
- Uninstall AeriVoice by quitting it and moving the app from Applications to
  Trash. Remove its preferences, Keychain entries, and Application Support data
  separately if you want a complete local reset.

AeriVoice does not upload its own crash reports. macOS or third-party providers
may collect diagnostics under their own settings and policies.

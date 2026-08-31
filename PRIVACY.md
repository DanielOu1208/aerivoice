# AeriVoice Privacy

This document describes the data flow in AeriVoice `0.1.0-beta.1`. AeriVoice
does not operate an account system, analytics service, or first-party backend.
It does use third-party transcription and AI providers selected by the user.

## Data sent to providers

### Soniox

While dictation is active, AeriVoice sends microphone audio to Soniox as a
realtime 16 kHz mono PCM stream. The Soniox API key, a random session reference,
and any vocabulary hints configured in AeriVoice are sent with the stream.
Soniox returns partial and final transcript tokens.

### OpenRouter or Groq

After Soniox finalizes a transcript, AeriVoice sends that transcript to the
selected cleanup provider. The request includes the selected model, reasoning
level, cleanup instructions, and the provider API key.

OpenRouter can route requests to an underlying model provider. AeriVoice asks
OpenRouter for zero-data-retention routing for its Gemini and GPT-OSS choices,
but provider behavior and terms remain controlled by OpenRouter and the
underlying provider. Direct Groq cleanup is experimental; review Groq's current
data controls before enabling it.

Provider pricing, retention, abuse monitoring, and privacy terms can change.
Review the current Soniox, OpenRouter, and Groq policies for your accounts.

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

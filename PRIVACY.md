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

When Cerebras is selected, AeriVoice may also send an authenticated connection
warm-up request when dictation starts. That request contains no audio or
transcript text and is limited to at most one attempt per minute.

Provider pricing, retention, abuse monitoring, and privacy terms can change.
Review the current Soniox, Meta, OpenRouter, Groq, and Cerebras policies for your accounts.

## Data stored on the Mac

- Provider API keys are stored in the macOS Keychain under the AeriVoice bundle
  identifier.
- App preferences, including selected providers and models, are stored with
  macOS preferences.
- Insertion uses the normal Paste shortcut. The transcript stays on the clipboard
  until you replace it; AeriVoice does not restore an earlier clipboard on a timer.
  The green check mark means the Paste shortcut was sent; macOS cannot confirm
  consumption by another app. Detected secure fields and secure keyboard-input mode copy with a warning
  instead of receiving an automatic Paste. Copies you make after dictation stops
  are preserved; if the clipboard changed, the transcript is not copied over it.
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

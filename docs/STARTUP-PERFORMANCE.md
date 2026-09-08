# Launch preparation and first activation

AeriVoice prepares audio resources once after launch, only when onboarding is
complete and microphone permission has already been granted. Preparation creates
an audio engine and calls `prepare()` without installing a capture tap or starting
the engine. It also reads the selected providers' credentials in the background
with the existing non-prompting Keychain policy. Those values are discarded;
activation reads the current credentials again.

The first activation can consume the prepared engine. The app checks the input
device, sample rate, and channel count before reuse. Engine configuration changes,
sleep, lock, cancellation, and quit discard unused preparation. Recording sessions
still release their engine when stopped; subsequent sessions use a fresh engine.
The converter still adapts to the actual audio callback's format.

Audio preparation and startup run on the audio queue. Activation during preparation
queues behind that work instead of creating another engine. Cancelled startup
checks cancellation before installing a capture tap and immediately before
starting the hardware. Cancellation of pending startup does not block the main
thread. Failure of optional preparation falls back to normal startup.

The existing notch, sound objects, and preliminary provider network request are
already prepared at launch. Sound playback, the 300 ms cue delay, and output muting
remain activation-time actions. No microphone capture or permission prompt is
part of launch preparation. Preparation is not retried on wake or after onboarding
in this initial version; the ordinary startup path remains available.

## Timing evidence

In the installed build 2026090604, the first recorded activation after its launch
had 2,382.6 ms activation-to-capture and 2,483.0 ms activation-to-first-audio.
The next nine activations had medians of 470.6 ms and 570.6 ms, respectively.
These existing logs locate most of that outlier before capture, but cannot identify
which individual local startup step caused it. They are not an after-change result.

New content-free milestones in the existing interaction JSONL separate:

| Interval | Milestones |
| --- | --- |
| Credential reads | `credentialReadStarted` to `credentialsReady` |
| Permission/readiness checks | `readinessCheckStarted` to `readinessChecksFinished` |
| Start sound call | `startCuePlaybackStarted` to `startCuePlaybackReturned` |
| Cue wait and scheduling | `startCuePlaybackReturned` to `startCueDelayFinished` |
| Output muting | `outputMuteStarted` to `outputMuteFinished` |
| Audio startup and queue wait | `audioEngineStartRequested` to `captureStarted` |

`preparedAudioEngineUsed` is present when preparation was reused. For new records
with both `audioEngineStartRequested` and `captureStarted`, its absence means a
fresh engine was used. Failed or cancelled startups cannot establish reuse. Older
records lack these new milestones and cannot establish preparation status.
Existing duration fields and older records remain compatible. No credential,
audio, transcript, vocabulary, or device identifier is added to the logs.

## Runtime acceptance

Automated tests cover the preparation lifecycle using fake audio engines, including
failure, device and format changes, immediate activation, cancellation during
startup, and stale completion. They do not establish actual microphone-indicator
behavior or a hardware latency improvement.

For a matched check on an updated development build:

1. Keep the input/output devices, provider, sound cues, and mute setting fixed.
2. Quit and launch the app. Confirm no microphone indicator, sound, output muting,
   or permission prompt appears during preparation.
3. After preparation has had time to finish, activate dictation, say the same short
   phrase, then stop. Repeat once immediately. Do three launch/activation pairs
   for each build, with the same launch-to-first-press delay.
4. Compare activation-to-capture and first-audio times separately from network and
   first-transcript times. Target first capture within about 150 ms of the immediate
   second activation. Also check an activation immediately after launch: it must
   remain usable while preparation finishes, although it can still pay that cost.
5. Cancel during startup and change the input device before first use. Confirm no
   late recording begins after cancellation and capture works on the new device.

Installation and a matched live before/after measurement are separate from source
and automated validation. Do not claim the cold-start spike is fixed until that
runtime check passes.

## Implementation validation (2026-09-07)

- Broad Debug suite: 262 passed, 3 live-provider tests skipped, no failures.
- After the final provider-failure cancellation fix: 67 focused audio, coordinator,
  and timing tests passed.
- Release build and Release static analysis passed; `git diff --check` passed.
- A standalone native preparation smoke, gated on already-granted microphone
  permission, completed in 154 ms and reported `AVAudioEngine.isRunning == false`.
  It installed no capture tap and did not start the engine. This checks the audio
  preparation layer, not the app UI indicator or first-activation latency.
- On user request, signed distribution build `2026090701` was installed and
  restarted. Its signature and executable hash were verified against the build,
  and the running process was verified at `/Applications/AeriVoice.app`.
- The distribution-configuration suite passed 263 tests with 3 live-provider
  tests skipped before installation. The previous build `2026090604` is backed up
  in `~/Library/Application Support/AeriVoice/Backups/AeriVoice-before-launch-preparation-2026090701.app`.
- The user-facing first-activation and microphone-indicator acceptance checks
  remain pending; installation alone does not establish a latency improvement.

# Optimization release candidate

Target: v0.2.1, based on v0.2.0-beta.1 (`9f09861`). Release notes: [v0.2.1](releases/v0.2.1.md).

## Implemented

- The notch uses a fixed transparent panel. Synchronized Core Animation keyframes animate
  the background, clipping mask, rim, and content opacity. Display callbacks
  track completion; transcript layout
  remains at its final size while the visible shape opens and closes.
- The existing 260 ms spring opening, 160 ms closing, and 80 ms Reduce Motion
  fade are retained. Interrupted transitions resume from the rendered geometry
  and opacity. Hidden status pulses pause and the display link stops.
- Transcript-only updates no longer repeatedly reorder the panel. Onboarding
  page changes now honor Reduce Motion.
- Clipboard backup capture gets up to 100 ms of asynchronous headroom before
  paste preparation. A stalled provider still cannot block the main thread or
  start additional snapshot workers for that pasteboard.
- An opt-in clipboard prototype supplies text through a pasteboard data provider.
  It retains exact editor verification when preparation succeeds; otherwise it
  can restore 500 ms after a post-dispatch text request, with target identity,
  ownership-marker, change-count, and generation checks. A read near the two-second
  no-read deadline gets its full grace period. No eligible read leaves materialized
  transcript text for manual paste. New user copies always take precedence.
- Overlapping prototype dictations carry the original pending backup forward.
  Starting the next recording lets the previous paste finish its restoration;
  explicit cancellation still invalidates it.
- Cerebras JSON is decoded before accepting a leading reasoning envelope, so
  literal `<think>` tags in dictated text are preserved. Groq and Cerebras reject
  explicit incomplete/refused responses through the existing raw-text fallback.
- Cancellation releases queued audio. Token-budget arithmetic is shared while
  provider limits stay separate. Write-only Soniox state and the obsolete notch
  window-frame interpolation helper were removed.

## Clipboard prototype contract

The production default remains exact editor verification. Set
`AERIVOICE_READ_AWARE_CLIPBOARD=1` explicitly to exercise the candidate fallback.
There is no new public setting and no automatic migration.

A data-provider callback proves only that a consumer requested text. It does not
identify the reader or establish insertion into the destination. Clipboard
managers can read after dispatch, and fulfilled data may be cached without further
callbacks. Pre-dispatch reads therefore disqualify receipt-based restoration;
transient/auto-generated markers reduce eager readers but do not prevent them.
This prototype must not be promoted based solely on named-pasteboard unit tests.

**Prototype promotion blocker:** an adversarial named-pasteboard test simulates
an unrelated reader after dispatch while the intended destination is delayed.
The prototype restores after that unrelated read; the delayed destination then
sees the original clipboard rather than the transcript. This characterizes a
known flaw of a reader-agnostic signal, not a successful restoration. The fallback
must remain opt-in and must not be promoted merely because ordinary trials pass.
A destination-specific acknowledgement or a separately accepted best-effort policy
would be needed before using it as the default.

The prototype records only enum outcomes through the existing opt-in diagnostics:
`restoredAfterRead` and `noEligibleRead`. Clipboard data and transcript contents
are never included. It has no transcript history or additional provider calls.

Research: [VoiceInk's delayed restoration](https://tryvoiceink.com/docs/clipboard-issues),
[Handy's experimental read-based path](https://github.com/cjpais/Handy/blob/main/src-tauri/src/paste_tx/macos.rs),
and [Apple's data-provider API](https://developer.apple.com/documentation/appkit/nspasteboarditemdataprovider).

## Reproducing synthetic QA

Debug builds include a deliberately isolated QA entry point. Setting
`AERIVOICE_OPTIMIZATION_QA` bypasses the normal app model, credentials, microphone,
preferences, and provider clients. Release builds exclude this entry point.

```sh
AERIVOICE_OPTIMIZATION_QA=notch \
AERIVOICE_QA_OUTPUT=/tmp/aerivoice-notch.json \
/path/to/AeriVoiceOptimizationQA.app/Contents/MacOS/AeriVoiceOptimizationQA
```

This shows 30 synthetic opening/closing cycles and writes content-free counters.
For insertion QA, use `AERIVOICE_OPTIMIZATION_QA=paste`, optionally with
`AERIVOICE_READ_AWARE_CLIPBOARD=1`. It waits five seconds for the tester to focus a
**disposable** field, inserts a fixed synthetic phrase, drains restoration, and
reports outcomes. Preserve the tester's clipboard first; no clipboard snapshot
is written to a file by the harness.

## Measured results

On the local MacBook Pro (macOS 27, Xcode 27), the clean baseline and
revised Core Animation candidate used the same 30-cycle Debug harness, with no
builds, tests, or trace exports running during either exercise:

| Counter | beta.1 baseline | Revised candidate |
| --- | ---: | ---: |
| Instruments detected hitches | 95 | 54 |
| Aggregate hitch duration | 1,008.33 ms | 491.67 ms |
| Longest detected hitch | 33.33 ms | 16.67 ms |
| Animation callbacks | 1,482 | 1,548 |
| Window frame changes during exercise | 1,482 | 0 |
| Measured callback work | 494.68 ms | 6.52 ms |
| Keyframe/transition setup work | Not separately measured | 16.06 ms |
| Display link stopped when hidden | Yes | Yes |
| Hidden pulse paused | Not implemented | Yes |

Detected hitches fell 43%, and aggregate hitch duration fell 51%. This passes the
synthetic hitch-count gate. It is one instrumented run per arm, not a Release
performance guarantee or visual acceptance. The baseline is the earlier clean
run; the candidate was rerun after the implementation changed. Candidate setup is
included separately so moving work out of callbacks is visible. These counters
do not measure total app/compositor CPU usage.

Evidence: `instruments-hitches-keyframes.json`,
`notch-baseline-clean-instrumented.json`, and
`notch-keyframes-clean-instrumented.json` in
`docs/benchmarks/2026-09-25-optimization/`.

The first fixed-panel implementation still mutated paths each frame. It reduced
callback work but failed the clean hitch gate: **95 → 136 hitches**, with aggregate
duration **1008.33 → 1274.99 ms**. This led to the keyframe revision. That failed
intermediate result is retained in `instruments-hitches-clean.json`. Earlier
untraced callback measurements and a build-contaminated trace pair are retained
for investigation only; they are not the final acceptance comparison.

## Validation and release gates

- Full final Debug suite: **549 passed, 3 opt-in tests skipped, 0 failures**.
- Release build and static analysis passed; Python release-tooling tests: **23 passed**.
- Independent review completed; its late-read grace-period finding was fixed and
  covered by a regression test.
- Developer ID signed, isolated Debug QA bundle built and signature verified.
- No live provider calls or microphone capture were used.


Automated tests cover literal reasoning tags, incomplete/refused responses, audio
cancellation with a suspended sender, transition interruptions, snapshot readiness,
background data callbacks, pre-dispatch reads, late reads, cancellation,
materialization, rich/empty clipboards, target changes, user copies, and overlapping
dictations. Tests use dedicated named pasteboards rather than the user's clipboard.

Native acceptance is still required: the computer-use service timed out twice
selecting TextEdit (`-10005 timeoutReached`) before any document or clipboard edits.
No successful real-editor paste or visual-appearance result is claimed.

Before release:

- Check shape orientation, rim/top seam, text clipping, rapid reopening, focus and
  click-through, Spaces/fullscreen, display changes, and Reduce Motion.
- Complete visible inspection alongside the recorded Instruments comparison.
  The synthetic hitch gate passed; visible smoothness and Release behavior
  still require native acceptance.
- Run 20 ordinary synthetic pastes per target in TextEdit, Safari, Chrome/Dia,
  VS Code, and Discord draft fields. Never submit messages. Check image/rich-text
  backups, delayed consumers, clipboard managers, rapid dictations, and newer copies.
- Any wrong-reader restoration or overwrite of a newer clipboard blocks prototype
  promotion. Otherwise review the real-app evidence before changing the default.
- Complete candidate acceptance, merged CI, signed/notarized release artifacts,
  and signed update-feed verification before publication.

No installation, merge, release tag, or public feed update is part of this local
candidate. Experimental orb and agent-context worktrees remain separate.

## Configurable delayed restoration (September 26 follow-up)

General → Clipboard now includes **Fallback restore delay**, defaulting to five
seconds with Never, 1, 2, 3, 5, and 10-second choices. Exact editor verification
still takes priority. When an editor cannot supply the initial text/cursor state,
a successfully dispatched Paste can restore after this delay. Dispatch is not
proof of insertion; an unnoticed paste failure can outlast the manual-paste window.
Exact verification that cannot confirm the edit (a terminal redraw such as Claude
Code in Ghostty, lost readback, or a focus change) also falls back to this delay,
measured from dispatch. Known blocked dispatches, and verifiable fields that stay
unchanged (an ignored Paste), leave dictation copied.

The timer checks the clipboard ownership marker, change count, and generation.
A new user copy wins. Rapid dictations carry the original backup forward; a later
recording that fails before writing resumes the earlier timer at its original
deadline. Switching focus does not cancel the delayed restoration. Turning off
restoration cancels pending work. Delay changes apply to subsequent pastes.

Regression tests cover image bytes, focus changes, new copies, explicit cancellation,
failed dispatch, ignored paste in verifiable editors, overlapping successful/failed
sessions, and stale cancellation after a previous timer resumes. These automated
checks do not replace real Ghostty/Codex acceptance.

Follow-up full Debug suite: **557 passed, 3 opt-in tests skipped, 0 failures**.

## Capture and provider follow-up (September 29)

### Microphone capture

- Capture continued 50 ms after stop in 0.2.1 and 0.2.2. Afterwards it was replaced by
  waiting for the tap block that holds the release and keeping only its frames before
  the release, so nothing said before release is lost; those frames and what the resampler
  still holds go out as one delivery, so the stream's tail is one frame; the stop cue
  and output unmute happen only after the microphone closes. (Initially 250 ms;
  reduced because most speakers finish before release. Tap buffers are ~100 ms and
  the partly filled one is dropped, so 50 ms mainly recovers speech just before release.) The insertion target is
  still captured at release. Cancel, errors, and the time limit skip the tail.
- The engine starts at key-down, overlapping the start cue. The capture service
  drops samples recorded before the cue deadline, now 200 ms (the Blow cue's loud
  attack; the output mute cuts its tail). Local logs showed recording began about
  475 ms after key-down with cues on (cue wait plus a ~100 ms cold engine start).
- After each dictation the next engine is prepared (not started; no microphone
  indicator). Bluetooth inputs are never prepared, to avoid switching headsets
  into the call profile.
- A device or format change during recording rebuilds capture on the current input
  while the transcription session stays open: notifications are debounced (150 ms),
  stale engines ignored, a running engine on an unchanged route is left alone, and
  restarts are capped at three. A failed restart finishes with the audio already
  captured and shows "Microphone disconnected".
- Multichannel inputs are mixed down instead of keeping only channel 0.
- An 80 Hz second-order high-pass filter removes rumble and DC offset
  (−24 dB at 20 Hz, −0.1 dB at 200 Hz).
- Dictation → Microphone has an input picker; System default remains the default.
  A disconnected choice falls back to the system default.

### Providers

Live probes (synthetic `say` speech, this Mac's network, n=12 per arm unless noted):

| Question | Result | Decision |
| --- | --- | --- |
| Grok `finalize` vs `audio.done` | 189 vs 179 ms median | Keep `audio.done` |
| Soniox manual finalize vs end-of-stream | 93 vs 98 ms median | Keep end-of-stream |
| Grok idle socket survival | 20 s … 600 s all survived | 5-minute prepared lifetime |
| Grok new connection to ready | 236 ms median, 291 ms p90 | Avoid on the critical path |
| Shared URLSession for WebSockets | 0/16 reused; 281 vs 280 ms | Not adopted |

- Grok prepared sockets live 5 minutes (was 30 seconds and never replaced), are
  pinged before adoption after 15 s idle, and are replaced after expiry for up to
  30 minutes after the last activity. xAI bills per audio second; idle probes show
  timestamps advance only with audio.
- Groq and OpenRouter connections are warmed at activation, as Cerebras already was.
- The OpenRouter catalog reads `expiration_date`: retired models are hidden, retiring
  ones are labeled, and Settings warns when the selected model is retiring.

### Cleanup preset candidates

Live Polished-mode comparison on the 20 compose-edge-20260914 transcripts, two runs
each, with the candidates configured exactly like the presets they would replace:

| Model | Success | Median | p90 |
| --- | ---: | ---: | ---: |
| GPT-5.6 Luna (current) | 40/40 | 1,052 ms | 1,544 ms |
| GPT-6 Luna | 40/40 | 1,231 ms | 1,638 ms |
| Gemini 3.7 Flash (current) | 38/40 | 2,412 ms | 4,132 ms |
| Gemini 3.8 Flash | 39/40 | 2,143 ms | 4,103 ms |

GPT-6 Luna produced near-identical text at half the price but ~180 ms slower.
Gemini 3.8 Flash was faster but dropped a sentence in both runs of one case, once
emitted literal `\n` escapes, and once resolved an ambiguous pronoun. Presets are
unchanged. Every Gemini failure was the exploratory whole-message retraction case.

### Validation

- Full Debug suite, three consecutive runs after code review: **586 passed, 3 opt-in
  tests skipped, 0 failures**. Release app and eval harness builds succeeded.
- Code review fixes: Grok preparation checks run on a fixed 60 s cadence and renew a
  slot in its final 30% (wake/unlock requests previously postponed the check past
  expiry); adoption pings only after 60 s idle with a 500 ms timeout; the notch panel
  is re-raised on phase changes; the clipboard backup reader runs at user-initiated
  priority (it was starved past its 100 ms budget under parallel test load).
- `testCancelledInsertionCannotCancelResumedPreviousRestoration` was intermittently
  failing (6/8 passing on the baseline, 2/8 on this branch). Instrumentation showed the
  restore timer waking ~70 ms late while `finishPendingRestoration`'s drain deadline
  had only a 50 ms margin, so the drain invalidated a restoration that was due. The
  drain now allows a 500 ms margin (10/10 passes). This path runs only before an
  update restart.
- No real-app acceptance yet: device switching (AirPods, USB, Sound settings), the
  capture tail and cue overlap, and the input picker need checks in the installed app.

# Offline mode validation — September 13, 2026

Validated locally and installed as signed build `2026091319`. No push or release publication was performed.

## Automated checks

- App suite: 398 passed, 3 skipped, no failures. The skipped tests require live cloud providers.
- Release build and static analysis passed.
- Harness regressions: 7 Local scenario tests, 4 Apple scenario tests, and 2 model-provenance tests passed. CI includes these scripts.
- Network-policy tests cover rejecting new HTTP/WebSocket work, cancellation of an intercepted URLSession request, caller cancellation, and rejecting late results after switching offline.
- Shortcut tests cover Hybrid/Toggle/Hold behavior, left/right Command and Option matching, legacy shortcut decoding, and release behavior.
- Apple tests cover asset readiness without downloads, unavailable languages, reservation failures, overlapping preparation, transcript revisions, and preserving audio during startup bursts.

## Live local inference

The Release harness transcribed a synthetic spoken sentence twice with Apple Speech (`en_US`) and twice with installed Nemotron weights. All four runs succeeded with `offline_mode: true` and cleanup bypassed. Neither engine downloaded assets during these runs.

Process socket sampling observed no internet sockets across 47 samples per engine. Sampling cannot prove the absence of every transient connection or inspect independent macOS services; the app network-policy tests provide separate coverage. These fixture runs are not a comparative accuracy benchmark.

## Native UI

A separate ad-hoc QA app with its own bundle identifier and preferences passed:

- Offline persistence, OFF → ON switching, and cleanup controls following the mode.
- Apple Speech ready state, language/model controls, Nemotron recommendation, and local accuracy caption.
- All three shortcut modes; cancelling side-specific re-recording preserves the prior shortcut and does not restart capture when reopening the page.
- Offline onboarding advances from provider setup to permissions without cloud credentials.
- At the updated 780 × 720 opening size, every General section through Startup is visible without scrolling or clipping.

The isolated QA apps were quit afterward. These checks did not change the installed app's credentials or permissions. No microphone recording or permission grants were used.

## Local installation

Build `2026091319` replaced `/Applications/AeriVoice.app` with the user's authorization. The bundle identifier, Developer ID signing requirement, and distribution Keychain namespace were preserved. Deep strict signature verification, candidate/installed executable hash equality, and the running executable path passed. The previous app was retained at `/Applications/.AeriVoice-before-settings-size-2026091319.app`.

Native automation could not inspect the installed app's Settings window; the visual fit check above used an isolated QA copy. The first attempt to shrink that copy stayed at 780 × 720, but a later resize lost automation access, so interactive minimum-size enforcement was not fully verified.

## Remaining device acceptance

Physical shortcut presses, actual microphone dictation and insertion into other apps, menu-bar interaction, missing-language downloads, and system asset retry behavior still need manual device acceptance. Trackpad gestures are deferred. Offline mode does not control macOS-managed asset maintenance or automatic retries of an Apple download requested earlier.

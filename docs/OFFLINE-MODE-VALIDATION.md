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

## September 14 follow-up: Apple setup and Providers

- The model's actual installed status now takes precedence over Apple's shared language list. A completed request that still has no usable assets displays an explicit failure instead of silently returning to Download.
- Providers includes Local models with a Manage sheet, shared setup controls, and a link to Dictation settings. Local management remains available offline while cloud account controls remain disabled.
- Full app suite: 402 passed, 3 live-cloud tests skipped. Regression coverage includes an installed model with a stale language list and an incomplete installation request.
- The production Apple installation request completed for English (Canada) and reported installed afterward. English assets were already present, so this does not establish a fresh missing-language transfer.
- Isolated native QA confirmed English ready on launch and reopening, en_CA → en_US → en_CA switching, the Providers sheet, offline control availability, and navigation to Dictation. No Download button was shown because English was already ready.
- Signed build `2026091401` was installed and relaunched with the existing identity and credential namespace. Installed signature, executable hash equality, and running path passed. Backup: `/Applications/.AeriVoice-before-apple-download-2026091401.app`.

### Local management belongs in Providers

Dictation now retains only provider/model selection and a Manage link alongside Dictionary and Microphone. Model downloads, language setup, status, and removal live in Providers. General and menu-bar setup links open that management sheet. Initial onboarding retains inline setup without links to unavailable Settings navigation.

Native QA passed model switching, direct Manage navigation, sheet dismissal without replay, missing-language setup navigation, and Offline mode preserving/restoring the saved cloud provider. No downloads or permission changes were used. The final full suite passed (401 tests, 3 live-cloud skips); Release build passed. Signed build `2026091402` was installed and relaunched, with signature, executable hash equality, and running path verified. Backup: `/Applications/.AeriVoice-before-local-management-2026091402.app`.

### Installed-app download incident and fresh-download check

The user and native QA reproduced English (Canada) remaining unavailable after a successful request in installed build `2026091402`. Checking again and retrying immediately did not recover it. A signed build with opt-in asset-status tracing (`2026091403`) reported English installed after relaunch; both the user and native QA confirmed Ready. The exact cause was not established: relaunch timing, process/app state, and diagnostic code changes were not independently controlled.

The prior optimized Release binary also reported English Ready under a fresh test-app identity. In a separate Developer ID-signed test copy, French (France) started missing, showed download progress after one click at 1.1 seconds, and was Ready at the 22.1-second observation, without errors or retries. English was restored and the test app quit; the shared French assets remain installed.

Build `2026091403` passed Release compilation, signature/hash/path checks, and installed native readiness inspection. The app was finally relaunched without the temporary `AeriVoiceSpeechAssetTrace` argument. Tracing is off by default and records only asset status, language identifiers, and reservations when explicitly enabled. No keys, permission settings, or downloaded models were removed.

### Final review: onboarding and download recovery

- Onboarding returns to the relevant earlier step when model readiness or permissions are lost. The final Start button now requires complete readiness, and an incomplete finish attempt also routes to recovery instead of silently doing nothing.
- Interrupted Nemotron downloads are discovered from staging on relaunch and offer Resume and Remove partial download. Cancellation preserves verified completed files; resuming does not fetch them again. Removal shows a busy state and blocks Resume until it completes, including during memory pressure.
- Apple language reservation first asks the system to recognize existing backing assets. It releases another reservation and retries only for `tooManyAssetLocalesAllocated`; equivalent variants and unrelated failures retain existing reservations.
- Full app suite: 410 passed, 3 live-cloud tests skipped. After a final manifest-validation guard, the 16 asset tests passed again. New regressions cover onboarding readiness loss, real task cancellation between files, partial-file removal after relaunch, removal/resume ordering, equivalent Apple reservations, capacity errors, and unrelated reservation errors.
- Release app and Release evaluation harness builds passed. Controlled local harness regressions: 7 passed; Apple harness regressions: 4 passed; model provenance regressions: 2 passed. `git diff --check` passed. Follow-up code review found no remaining issues in these fixes.
- This pass did not install or restart the production app, download real model weights, mutate Apple language assets, grant permissions, or repeat native UI/microphone acceptance. The earlier English (Canada) incident's exact cause remains unconfirmed.

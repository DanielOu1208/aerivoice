# Performance logging and collection

AeriVoice can record content-free diagnostics locally under **Settings → Privacy & Data → Performance diagnostics**. Logging is disabled by default; explicitly saved on/off choices are preserved. Enable it when investigating a problem or collecting measurements to share manually. This is measurement infrastructure for a person or agent to analyze; it does not upload records or compare builds automatically.

## Files and controls

Automatic history lives in `~/Library/Application Support/AeriVoice/Benchmarks`:

| File | Contents |
| --- | --- |
| `interactions-v1.jsonl` | Completed dictation attempts, including failures and cancellations |
| `runtime-v1.jsonl` | Initialization, activity, settings, preparation, sleep/wake, and resource observations |
| `active-interaction-v1.json` | Latest checkpoint for an unfinished interaction |
| `Archives/{interactions,runtime}-v1-<timestamp>-<UUID>.jsonl` | Rotated completed segments |

Each JSONL line is one JSON object. Streams rotate daily or at 8,000,000 bytes. Recognized diagnostics have a 200,000,000-byte total budget and completed records expire after 365 days. Maintenance runs on logging writes, including idle samples; it does not require another dictation. The oldest completed segments are removed first under space pressure. A live checkpoint is protected, so an artificially tiny budget can be exceeded by that checkpoint alone. Malformed lines count toward the budget; unreadable timestamps use segment modification time for age expiry. Unknown files are left alone. Directories use mode 0700 and files 0600; symlink destinations are rejected.

**Clear Completed History** clears both completed streams and their archives and invalidates pending resource observations. It preserves a dictation in progress. New observations can appear after clearing while logging remains on.

Turning logging off cancels the idle timer, stops signposts and new collection, invalidates queued collection, and discards the recovery checkpoint. A final `loggingDisabled` control marker tells external observers to stop trusting the prior idle state. Existing completed history is retained. A durable generation change prevents a checkpoint from before opt-out being recovered on a later launch. A write already executing can finish before the ordered discard. Enabling logging later records `loggingEnabled`; it does not invent earlier startup measurements.

## Interaction schema

`schemaVersion` remains 1. Existing fields and readers remain compatible; new fields are optional:

| Field | Meaning |
| --- | --- |
| `interactionID` | Deduplication key across current, archived, and copied records |
| `recordingGeneration` | Recovery authorization generation, changed when logging is disabled |
| `context.launchID` | Random identity for this process launch |
| `context.activationIndex` | Attempt number since launch, including attempts while logging was disabled |
| `context.sinceLaunchMS` | Activation time relative to the first statement in `main.swift` |
| `context.sincePreviousInteractionMS` | Time since the preceding attempt finished; includes settling/teardown, so it is not proof of continuous idle |
| `context.sinceWakeMS` | Time since the latest observed wake, absent before one is observed |
| `context.settings` | Selected provider/model/mode/reasoning, sound/mute/activation settings, and onboarding completion |
| `environment` | App version/build, running executable UUID, Debug/Release, distribution flag, optional embedded source revision, macOS/architecture, machine model, RAM bytes, logical CPU count |

`milestonesMS` contains monotonic offsets from activation. `durationsMS` retains the existing local/provider stage boundaries. `stopToOutputMS` ends at insertion completion; when `outcome.terminalResult` is `pasteSent`, that means Paste dispatch, **not confirmed destination consumption**. Interrupted recovery uses the last checkpoint time, not the next launch time.

A missing value is unavailable or not reached, never an assumed zero. Keep terminal outcomes and cleanup routing/fallback fields when analyzing timings. Do not compare successful insertion with clipboard-only or failed attempts as though they measured the same operation.

## Runtime schema and units

Every runtime record has `schemaVersion: 1`, `recordID`, `launchID`, `processID`, `recordedAt`, `uptimeMS`, `sinceLaunchMS`, `event`, `activity`, `activityGeneration`, `environment`, `settings`, and cumulative dropped-write/sample counts. `interactionID` associates a record with an attempt when available. Dates are UTC ISO 8601 with milliseconds; readers also accept older dates without fractions.

`uptimeMS` uses the continuous Mach clock, which includes sleep. `sinceLaunchMS` measures app initialization from `main`, excluding OS work before it. Menu configuration and `shortcutEnabled` are separate events. `shortcutUnavailable` reflects an actual event-tap failure. Initialization completion does not mean asynchronous audio preparation or network warmup has completed.

Events cover initialization start/end, menu and shortcut availability, preparation start/end/skip, network warmup start/end, interactions and phase changes, session cleanup, Settings visibility/changes, sleep/wake, logging changes, termination, and resource availability. Preparation `result` is `prepared`, `skipped`, `failed`, `cancelled`, or `unknown`.

`activity` is one of `launching`, `preparing`, `dictating`, `settling`, `settings`, `idle`, or `sleeping`. Preparation and session settling are work even if no interaction record is being written. `activityGeneration` changes at measurement boundaries, including transitions within dictation, sleep/wake, and clear/enable changes. Only compare resource deltas inside the same generation. Settings changes include only the documented non-content settings.

Resource observations have an optional `resources` object:

| Field | Unit and boundary |
| --- | --- |
| `sampledAt`, `uptimeMS` | Actual counter acquisition time; can precede record delivery time |
| `userCPUMS`, `systemCPUMS` | Cumulative process CPU milliseconds, converted from native ticks through the machine timebase |
| `physicalFootprintBytes` | Current process physical memory footprint |
| `lifetimePeakFootprintBytes` | Lifetime process peak; **not** a per-stage or per-interaction peak |
| `diskReadBytes`, `diskWriteBytes` | Cumulative process disk I/O counters |
| `idleWakeups`, `interruptWakeups` | Cumulative platform-idle and interrupt wakeup counters |
| `thermalState`, `lowPowerMode`, `powerSource` | Thermal state, low-power setting, and `ac`/`battery`/`unknown` context |

`resourceInterval` appears only when both samples are available and counters/time are monotonic in the same generation. It contains elapsed milliseconds, CPU milliseconds, average CPU percent, and I/O/wakeup deltas. CPU percent = 100 × CPU milliseconds / elapsed milliseconds: 100% means one logical CPU, and multicore work can exceed it. Counter failure emits `resourceUnavailable` with absent resources, not zeros.

Optional `audioRoute` contains only `transport` (`builtIn`, `bluetooth`, `usb`, `other`, or `unknown`), sample rate in Hz, and channel count. It describes the observed default input, not a guarantee that a session used that route throughout. Reading it does not start capture. Device IDs and names are not persisted.

Resources are sampled at major boundaries and approximately every five idle minutes with 30 seconds of timer leeway. At most one background sampler runs; bursts coalesce. `droppedResourceSamples` includes coalesced or invalidated observations, and `droppedWrites` identifies queue pressure. Ordinary writes are bounded to 128 pending entries. Final interaction results and control operations keep their ordering under pressure. Persistence failures do not stop dictation. No sampling or disk writes occur in audio callbacks.

Instruments can display content-free intervals under subsystem `com.danielou.AeriVoice`, category `Performance`: Initialization, Audio preparation, Network prewarming, Capture startup, Recording, Transcription finalization, Cleanup, and Insertion. Failure/cancellation closes open intervals. Logging must be enabled.

## Collect a controlled run

Use an optimized Release app without a debugger, coverage, or sanitizers. The runner attaches to an already running app. It does not install, restart, open Settings, trigger dictation, paste, or call a provider itself. Enable performance logging before collecting.

```sh
# Resolve exactly one running AeriVoice and collect five minutes at 1 Hz.
swift scripts/record-performance.swift --mode idle

# Explicitly select a PID if multiple instances are running.
swift scripts/record-performance.swift --mode idle --pid 12345 --duration 300

# Collect ten attempts, with a 15-minute timeout.
swift scripts/record-performance.swift --mode dictation --count 10 --duration 900

# Optional output must be a new directory, not an existing parent.
swift scripts/record-performance.swift --mode idle --output /tmp/aerivoice-run-unique
```

For guided dictation, select a safe text destination yourself, use the normal shortcut, and say the same phrase on each attempt:

> The quick brown fox jumps over the lazy dog. Please send the meeting notes tomorrow morning.

Failures, empty attempts, and cancellations count. Attempts begun before collection are excluded. The phrase is printed by the runner, never added to diagnostic records.

Default run folders live under `~/Library/Application Support/AeriVoice/BenchmarkRuns`, outside automatic retention. Each contains `manifest.json`, `resources-v1.jsonl`, and copied matching `runtime-v1.jsonl`/`interactions-v1.jsonl`. Delete these folders explicitly when no longer needed. The manifest identifies the scenario, process launch, executable UUID/SHA-256, settings, requested limits, counts, and completion status. UUID verification compares the running process with `dwarfdump` before collection; the runner rechecks process identity and executable metadata during the run and hashes again at the end. It never labels an installed binary using the current checkout revision.

A resource row's `precedingIntervalActivity` is `observed_idle` only with a recent matching idle baseline and no observed activity-generation or dropped-write change. Otherwise it is `unknown`, which must be excluded from idle calculations. The first interval is unknown. Collection completion means the requested duration/attempt count was collected, not that every interval was idle. Missing/stale runtime context (over 360 seconds), disabled logging, process exit/replacement, Ctrl-C, or timeout preserve a partial run with a reason. Exit status is 0 for complete, 2 for partial, and 1 for setup failure. No-runtime older builds cannot supply trustworthy idle/guided runs.

Runner resource rows use `continuousMS` and `elapsedMS` for clocks, `lifetimePeakPhysicalFootprintBytes` for the lifetime peak, and `platformIdleWakeups` for platform-idle wakeups; other counter names/units match the automatic stream. These are cumulative counters, so calculate differences between successive rows from the same process identity. The observer's own CPU belongs to the runner process, not AeriVoice; the observation can still perturb the machine.

## Build identity, analysis, and acceptance

Release packaging embeds `AeriVoiceSourceRevision` and writes executable and dSYM UUIDs to `release-info.txt`. A local build without an embedded revision leaves it absent. Version numbers alone do not establish identical builds; use UUID/hash and retain the corresponding symbols. `buildConfiguration` describes the compiled app; the separate synthetic provider harness additionally records `measurementBoundary: generated-audio-to-cleaned-text-no-capture-or-insertion`. Its measurements exclude real microphone startup, shortcut handling, and destination insertion.

```sh
# Summarize current plus archived interactions (deduplicated by interactionID).
swift scripts/summarize-latency.swift
# Existing single-file input remains supported, including copied run files.
swift scripts/summarize-latency.swift /path/to/run/interactions-v1.jsonl
# Inspect a candidate binary and symbols without launching it.
dwarfdump --uuid /path/to/AeriVoice.app/Contents/MacOS/AeriVoice
# Offline collector fixtures; no microphone, providers, or installed-app changes.
python3 scripts/test-record-performance.py
```

Deduplicate interaction copies by `interactionID` and runtime copies by `recordID`. Group by executable identity, machine/OS, configuration, settings, route, power/thermal state, and outcome before comparing. Keep everyday use, controlled real-app runs, and synthetic provider runs separate. Compare first activation (`activationIndex == 1`) with the second in the same launch; repeat launch pairs under the same permission/setup conditions. Do not call every first activation cold: provider/network state, wake timing, and launch preparation matter.

Separate local activation/capture/insertion time from provider/network time. Keep sample counts, failures, missing fields, and dropped observations beside any percentiles. Sparse memory samples cannot establish exact transient peaks. The runner adds denser observations, not exact attribution of CPU or memory to individual functions.

Before a release, record an actual no-debugger Release acceptance session: fresh-launch/second-activation pairs, an idle run, guided dictations including cancellation, Settings activity, and sleep/wake. Confirm that diagnostics add no microphone activation or insertion changes. Measure logging on versus off on the same Mac with matching inputs and configuration; use an external Instruments/resource measurement while logging is off, since this runner intentionally refuses an unverifiable idle state. Automated counter, lifecycle, storage, and runner tests do not establish that real-device acceptance or quantify logging overhead.

Implementation verification on 2026-09-07: the full Debug suite passed 283 tests with three opt-in live-provider benchmarks skipped. Subsequent focused runs passed all 12 runtime and nine storage tests after the final changes. Offline collector/archive-reader fixtures, Debug static analysis, and the unsigned optimized Release build passed; the Release executable and dSYM UUIDs match. No app was installed or restarted. Real-app launch pairs, guided dictation, idle/sleep-wake acceptance, and logging-on/off overhead measurement remain release acceptance work; no performance improvement or overhead figure is claimed here.

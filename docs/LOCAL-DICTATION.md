# Local dictation

Select **Local** in Dictation settings, then choose **Apple Speech** or **NVIDIA Nemotron — Recommended**. Nemotron 3.5 uses English, 560 ms chunks, and an explicit download of approximately 611 MB. Accuracy may be lower than cloud models. The same setup is available during onboarding. Nemotron uses the existing Dictionary as recognition hints from the next recording. English hints shorter than three characters are retained in the Dictionary but not used by this engine. Hints do not guarantee spelling.

Weights stay in `~/Library/Application Support/AeriVoice/LocalModels/`. The download verifies a pinned inventory and SHA-256 hashes, preserves verified staged files for retry, and exposes the installed directory only after verification. Runtime verifies it again before loading. No account or transcription API key is required. Model preparation happens while Local is selected; speech is not captured during preparation. Press the shortcut again when ready. Switching providers or memory pressure releases the model after any active recording finishes.

Nemotron transcription runs on this Mac using FluidAudio 0.15.7 and Core ML. Outside Offline mode, existing cleanup settings still apply: a cloud cleanup provider may receive the transcript. Local does not automatically fall back to a cloud transcription provider.

## Apple Speech and Offline mode

Apple Speech uses macOS 26's SpeechAnalyzer and SpeechTranscriber. It performs transcription on this Mac without a cloud transcription account or the NVIDIA weights. Choose a supported language; the Mac's primary language is suggested when supported. Existing Apple language assets are reused. Missing language support requires an explicit Apple-managed download with progress. There is no fallback to the older Apple engine or cloud transcription. Apple Intelligence is not a separate requirement or cleanup option.

Enable **Offline mode** from General, the menu bar, or local-model onboarding after the selected engine is installed. Offline mode uses that local engine and inserts its transcript without AI cleanup. No cloud API keys are required to complete offline setup. Normal provider and cleanup selections remain saved and return when Offline mode is turned off. The choice survives quitting and reopening the app.

The mode cannot change during dictation or while an Apple language download request remains active. It blocks new AeriVoice-initiated network requests, including cleanup, provider warmups, credential checks, catalog refreshes, and model downloads; pending app requests are cancelled. It is not a system firewall and cannot stop macOS maintenance of shared Apple assets, including automatic retries of a previously requested download after its initial attempt fails. While offline, only installed local engines/languages can be selected. Missing or failed assets keep the app offline; downloading a repair requires turning Offline mode off.

## Activation shortcuts

Hybrid remains the default: tap to toggle, or hold at least 350 ms and release to finish. Toggle starts and finishes on successive presses. Hold starts immediately and finishes on release, including quick taps. Modifier-only combinations finish when the first required modifier is released; ordinary-key combinations finish when that key is released. Escape cancels.

**Distinguish left and right keys** optionally matches the exact Command and Option keys. Enabling it asks you to record the shortcut again; cancelling preserves the previous shortcut. Existing shortcuts continue accepting either side. Built-in trackpad gestures are deferred.

## Integration and versions

- FluidAudio: exact Swift package version 0.15.7.
- Converted model: `FluidInference/Nemotron-3.5-ASR-Streaming-Multilingual-0.6b-CoreML`, revision `1a41b75758b0337ff67db7d5408280aaaf23074e`, `latin/560ms`.
- The multilingual engine is deliberately used with `en-US`; it supports streaming custom vocabulary. The original English-only manager does not provide this integration.
- App distribution includes `LocalModel-LICENSE.txt`, with model, library, and bundled third-party notices. Weights are downloaded separately, not included in Git or the app.

## Automated validation

Use the existing `aerivoice-evals` controller against this worktree's Release harness. Build provenance must identify the exact source and executable used. Run `AeriVoiceEvalHarness download-local-model` once to exercise the production downloader without opening or installing the app.

Local scenarios use `mode: live`, `kind: transcription`, and `transcription_provider: local`: real local inference with cleanup bypassed. `prepared` retains its existing audio-preparation meaning. Model loading always finishes before fixture playback; `local_preparation_finished` records total verification/preparation and engine-load time separately. Model provenance includes actual file hashes. Warm session timing excludes model preparation. Compute stop-to-final from `sttFinalized - stopRequested`, not clipboard delivery or first partial text.

The app ships only 560 ms. Benchmark-only `local_model_path` and `local_model_variant: 1120ms` allow an external comparison model; the harness checks the variant metadata and records actual hashes. Verification and reporting share one file-hash record, so the default model is hashed once per preparation. External files that do not match the pinned manifest report `model_revision: null` and `matches_bundled_manifest: false`. Use the same pinned model revision for comparisons, alternate A/B then B/A processes, and retain the download receipt to establish the external variant's revision; its metadata alone does not prove that revision.

Controlled Local scenarios honor `connect_delay_ms`, `finalize_delay_ms`, and the `connection` and `finalize_timeout` faults. A finalization fault injects the timeout error after the configured delay; it does not measure an engine timeout. `malformed_stt` is rejected for Local because there is no network response parser. `cancel_sessions` selects which repetitions to cancel in both transcription and cleanup runs; it is rejected for conversion runs.

Run the offline regression checks against a freshly built harness:

```sh
python3 scripts/test-local-eval.py /path/to/AeriVoiceEvalHarness -v
python3 scripts/test-local-model-provenance.py -v
python3 scripts/test-apple-eval.py /path/to/AeriVoiceEvalHarness -v
```

These checks use synthetic files and controlled responses, without downloading or loading model weights.

Record failures, cancellations, missing samples, dictionary false additions, raw transcript scores, and reference-review status alongside timing. Text scores do not replace human listening. Neither harness insertion nor green automation establishes microphone, native UI, installed-app, or battery acceptance.

For Apple evaluation, add `local_model: apple` and `apple_locale: en-US` (or another supported installed locale) to a Local scenario. Live evaluation checks installed assets only and never downloads them. Records identify the Apple engine and language with `model_revision: null`, because macOS manages the model version. Omitted `local_model` retains Nemotron. Apple scenarios cannot include Nemotron model paths or variants. Controlled Apple scenarios use the same injected responses and fault controls as other Local scenarios.

Set `offline_mode: true` on a Local pipeline scenario to exercise the app-wide network policy and production cleanup bypass together. This requires installed assets for live runs and never downloads them.

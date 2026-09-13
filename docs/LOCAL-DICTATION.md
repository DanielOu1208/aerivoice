# Local dictation

Select **Local** in Dictation settings, then explicitly download Nemotron 3.5 (English, 560 ms chunks; approximately 611 MB). The same setup is available during onboarding. Local uses the existing Dictionary as recognition hints from the next recording. English hints shorter than three characters are retained in the Dictionary but not used by this engine. Hints do not guarantee spelling.

Weights stay in `~/Library/Application Support/AeriVoice/LocalModels/`. The download verifies a pinned inventory and SHA-256 hashes, preserves verified staged files for retry, and exposes the installed directory only after verification. Runtime verifies it again before loading. No account or transcription API key is required. Model preparation happens while Local is selected; speech is not captured during preparation. Press the shortcut again when ready. Switching providers or memory pressure releases the model after any active recording finishes.

Audio transcription runs on this Mac using FluidAudio 0.15.7 and Core ML. Existing cleanup settings still apply: a cloud cleanup provider may receive the transcript. Local does not automatically fall back to a cloud transcription provider. This feature does not make cloud cleanup free or offline.

## Integration and versions

- FluidAudio: exact Swift package version 0.15.7.
- Converted model: `FluidInference/Nemotron-3.5-ASR-Streaming-Multilingual-0.6b-CoreML`, revision `1a41b75758b0337ff67db7d5408280aaaf23074e`, `latin/560ms`.
- The multilingual engine is deliberately used with `en-US`; it supports streaming custom vocabulary. The original English-only manager does not provide this integration.
- App distribution includes `LocalModel-LICENSE.txt`, with model, library, and bundled third-party notices. Weights are downloaded separately, not included in Git or the app.

## Automated validation

Use the existing `aerivoice-evals` controller against this worktree's Release harness. Build provenance must identify the exact source and executable used. Run `AeriVoiceEvalHarness download-local-model` once to exercise the production downloader without opening or installing the app.

Local scenarios use `mode: live`, `kind: transcription`, and `transcription_provider: local`: real local inference with cleanup bypassed. `prepared` retains its existing audio-preparation meaning. Model loading always finishes before fixture playback; `local_preparation_finished` records total verification/preparation and engine-load time separately. Model provenance includes actual file hashes. Warm session timing excludes model preparation. Compute stop-to-final from `sttFinalized - stopRequested`, not clipboard delivery or first partial text.

The app ships only 560 ms. Benchmark-only `local_model_path` and `local_model_variant: 1120ms` allow an external comparison model; the harness checks the variant metadata and records actual hashes. Use the same pinned model revision, alternate A/B then B/A processes, and retain the download receipt. External 1120 ms inputs are explicitly marked as not matching the bundled 560 ms manifest.

Record failures, cancellations, missing samples, dictionary false additions, raw transcript scores, and reference-review status alongside timing. Text scores do not replace human listening. Neither harness insertion nor green automation establishes microphone, native UI, installed-app, or battery acceptance.

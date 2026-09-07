# Chinese cleanup smoke benchmark — 2026-09-06

Six live requests through the production CerebrasCleanupClient, using the current English CleanupPrompt and qwen-3.8-27b with reasoning disabled. Three synthetic transcripts (Simplified Chinese, Traditional Chinese, mixed Chinese–English), each tested once in Faithful and Polished mode. No microphone, Soniox, or paste operation was involved. This isolates cleanup; it is not an end-to-end dictation latency measurement or an English-versus-Chinese prompt comparison.

All six requests returned nonempty structured output. Manual inspection found Chinese preserved in 6/6, script preserved in the four monolingual cases, and all English technical terms preserved in both mixed cases. These are small-sample observations, not general accuracy estimates. XCTest checks request completion/nonempty output, not semantic correctness.

Faithful mode retained fillers in all three cases and left the spoken time correction in place. The Simplified Faithful output also retained a repeated 我. Polished mode resolved the time correction to four o'clock in both monolingual cases and preserved the amount and recipient, but retained 嗯 in the mixed-language sample. Thus language preservation worked in these samples, while filler removal was incomplete.

Cleanup elapsed time: median 284.7 ms, range 226.7–371.1 ms. Requests ran sequentially through one ephemeral session without explicit warm-up. Six different cases are insufficient for reliable tail-latency comparisons.

Exact synthetic inputs, outputs, model identity, token counts, elapsed times, and provider queue times are in 2026-09-06-chinese-cleanup.jsonl. Credentials were read from an existing local provider configuration and passed through a private FIFO, never written to the report, logs, or command arguments.

Harness: AeriVoiceTests/MultilingualCleanupLiveBenchmarkTests.swift. It skips unless /tmp/aerivoice-multilingual-benchmark.plist explicitly provides credentialPipePath and outputPath. The pipe must supply only the UTF-8 Cerebras key and close. The normal production prompt and installed apps were unchanged.

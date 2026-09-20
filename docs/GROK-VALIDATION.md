# Grok Voice Transcribe 2.0 validation

This development branch adds Grok to the beta.9 release baseline (`0ffab0d`).
It does not incorporate the later main-branch visual changes. Grok is optional;
the existing default providers and cleanup behavior are preserved.

## Implemented behavior

- Streaming uses `wss://api.x.ai/v1/stt`, explicitly pinned to
  `grok-voice-transcribe-2.0`, with native 16 kHz mono PCM and interim results.
  Audio starts only after `transcript.created`.
- Dictionary entries remain saved unchanged. The first 100 eligible terms of
  at most 50 Unicode code points are sent as repeated `keyterm` parameters.
  Literal `+` characters are encoded correctly. Excluded entries are disclosed
  in Dictation settings; hints do not guarantee spelling.
- Capture-sized packets use cumulative deadlines. A full-packet scheduling stall
  rebases the deadline rather than causing a burst. Captured backlog sends at
  up to 1.35× real time, then returns to 1× when the queue clears. PCM bytes,
  sample rate, and pitch do not change. The internal 100 ms evaluation mode also
  counts buffered packets when deciding whether backlog remains.
- `flushAudio` reaches the actual transport before finalization. Sent-byte
  telemetry counts successful transport writes, not buffer acceptance.
- One authenticated, audio-free connection can be prepared for 30 seconds after
  readiness. Adoption checks the actual key, model, and effective dictionary.
  Sleep, lock, offline mode, cancellation, and relevant configuration changes
  invalidate preparation. There is no idle audio, ping, or reconnect loop.
  Successful insertion can prepare the next connection.
- `audio.done` flushes the remaining transcript and closes the session. Default
  endpointing is retained; Smart Turn is not enabled. Chunk finals are deltas;
  stitched utterance finals replace their overlapping chunks. An empty terminal
  acknowledgement preserves only confirmed text, never interim text.
- xAI credentials use the existing macOS Keychain boundary. Requests, keys,
  vocabulary-bearing URLs, and provider response bodies are not placed in
  diagnostic errors. Offline mode prevents cloud traffic.
- Providers and Dictation expose Grok (xAI). The provider icon uses the official
  SpaceX mark, with source/trademark attribution in
  [ProviderIcons-LICENSE.txt](../AeriVoice/ProviderIcons-LICENSE.txt).

## Automated and native validation

The final Debug suite passed 470 tests with three skips and no failures; static
analysis passed. The focused Grok client run passed 36 tests. Deterministic
catch-up checks verify byte preservation, small tails, return to real time,
internally buffered packets, and a stalled sender resuming without a burst.
A focused independent review found no issues in the pacing or icon changes.

The final Release app build and static analysis passed. Release harness checks
passed with no skips or failures: Grok 8/8, local 7/7, Apple Speech 4/4, and model
provenance 2/2. The evaluation harness tests cover explicit packet modes, actual-write events,
flush ordering, ready adoption, failed preparation, and the default packet mode.
The private lab has a pre-existing custom-instruction Unicode-boundary test
failure, separate from these provider checks; it is not claimed as passing.

Native checks previously verified the beta.9 navigation, Grok provider/model
selection, saved-key status, and the secure connection sheet. Microphone access
was allowed. Microphone-to-TextEdit acceptance remains blocked by the isolated
preview's macOS Accessibility authentication. Harness success is not native
microphone or insertion acceptance. The production application is not replaced
by the isolated preview.

The updated isolated Release preview launched and its running executable path
was verified. Live Settings inspection failed with `AXError.cannotComplete`,
then timed out on one retry. The new icon's asset mapping, 48×48 source image,
and light/dark render were verified, but its final in-app appearance remains
unverified. No authentication or preference changes were made during that check.

## Matched packet and connection experiment

Three fixed English, Chinese, and mixed-language clips, five repetitions each,
were tested across seven variants in rotated/reversed order: 105 calls, all
successful, with no retries or skipped providers. Cleanup was bypassed and
insertion simulated. References remain pending listening review, so accuracy
scores are provisional. These are stop-to-result timings, not desktop-paste
measurements.

| Variant | Median stop ms | p90 stop ms |
| --- | ---: | ---: |
| Previous Grok, fresh | 1074.6 | 1227.3 |
| Corrected capture-sized Grok, fresh, 1× | 648.2 | 867.7 |
| Corrected capture-sized Grok, ready, 1× | 325.5 | 587.3 |
| Corrected 100 ms Grok, fresh, 1× | 574.9 | 756.2 |
| Corrected 100 ms Grok, ready, 1× | 383.9 | 581.0 |
| Soniox | 127.3 | 165.1 |
| Muse | 180.5 | 236.4 |

The predeclared rule required 100 ms packets to remain within +25 ms median and
+50 ms p90 of capture-sized packets in both connection modes. The ready median
was +58.4 ms, so capture-sized packets were selected. Both ready variants hit
15/15 times. Selected-mode median startup was 0.6 ms versus 285.8 ms fresh;
preparation itself cost 283.9 ms and is excluded from activation. Median send
schedule excess was 3.2 ms ready / 4.5 ms fresh. Ready queue drain was 1.9 ms,
with finalization still 320.5 ms. All actual writes preserved captured bytes.

All 27 follow-ons were recorded: 24 speech/pipeline successes and three expected
empty-transcript silence results. Dictionary hints improved literal
`TextInsertionService.swift` and `AeriVoice` hits from 0/3 to 3/3 in each tested
English and mixed technical clip. Ready-age probes hit at 5 and 25 seconds;
a 35-second expired slot successfully fell back to a fresh connection.

Two 63.32-second trials per configuration had stop latency of 3789–4014 ms
previously, 612–708 ms corrected fresh, and 236–403 ms corrected ready. Corrected
send-schedule excess ranged 19–102 ms. The active recording remained open past
30 seconds; the timer expires only an unused prepared connection.

The frozen previous binary SHA-256 is
`06d99b3d2aa4b25d7e71c6628c73aed6001f66e4bdbc0167ea5b3ff77382e1db`;
the corrected comparison binary is
`9e426a31e929936164aad0d98eb632ce73355f187021b72fa631c56ac20b6bb8`.
The private lab retains raw events, source/build snapshots, fixture hashes,
and every attempted slot. Its 132-slot duration-based STT estimate was $0.0902,
versus a deliberately conservative $1.4712 reservation. Neither is an invoice.

## Catch-up and finalization experiment

A separate direct Swift WebSocket adapter compared five configurations using
three fixed clips and three repetitions each, in rotated/reversed order.
All 45 calls completed without retries or errors and with matching input/wire
PCM hashes. These measurements motivated the production change; they are not
measurements of the final application binary.

| Configuration | Median stop ms | p90 stop ms |
| --- | ---: | ---: |
| Fresh, 1× | 607.7 | 983.3 |
| Fresh, bounded 1.35× catch-up | 317.6 | 459.5 |
| Ready, current `audio.done` | 287.7 | 409.6 |
| Ready, explicit `finalize`, qualified text available | 309.5 | 623.0 |
| Ready, endpointing reduced to 100 ms | 300.4 | 397.8 |

Catch-up improved all nine paired cold comparisons by 98–688 ms. Queue drain
fell from median 308.9 ms to 39.6 ms. All nine returned to 1× before capture
ended, clearing their initial backlog approximately 0.65–0.86 seconds after
connection. No clear catch-up-specific content regression was identified in
paired transcripts; this small corpus is not a general accuracy guarantee.

The explicit-finalize timestamps above require a new utterance final covering
the complete input and matching the eventual terminal transcript, which passed
9/9 checks. Its later connection close is excluded. Neither that option nor
shorter endpointing showed a consistent speed benefit, so current finalization
is retained. With nine samples, nearest-rank p90 is the maximum. Outliers remain
included. Estimated audio cost was $0.0161; the $0.25 reservation was not spend.

xAI documents real-time-paced streaming without an explicit supported catch-up
multiplier. The bounded 1.35× behavior has local empirical validation, not a
provider guarantee. It does not replay audio after a failed write.

## Final production catch-up retest

The final Release harness compared unchanged 1× pacing with production 1.35×
catch-up: three fixed English, Chinese, and mixed-language clips, three
repetitions each, in nine alternating pairs. Both binaries used explicit
capture-sized packets, fresh connections, dictionary off, and identical
48 kHz capture input with 1024-frame feeds. All 18 calls succeeded without
retries or ready-connection hits.

| Fresh-connection configuration | Median stop ms | p90 stop ms | Median queue drain ms |
| --- | ---: | ---: | ---: |
| Before catch-up, 1× | 585.5 | 776.8 | 279.5 |
| Production catch-up, up to 1.35× | 342.1 | 386.7 | 34.1 |

Every pair improved by 164–468 ms. The median stop delay fell approximately
42%. Captured byte counts matched across pairs; actual-write byte totals
matched capture and sent-byte telemetry. Flush preceded queue-drained and
`audio.done`. Fixture hashes were verified; this harness does not independently
hash wire contents. No resource gaps above five seconds occurred. With nine
samples per variant, nearest-rank p90 is the maximum; all samples are retained.

Chinese transcripts matched in all three pairs. English spelling/capitalization
and some mixed-language wording varied with dictionary off. No clear new
omission was identified, but auditory reference review remains pending.

The final frozen harness SHA-256 is
`f54aa470a00f07bc8bf2198987b7dd633157d4bfc3d3debe8ffd88cd2ff4d6c5`;
the baseline is the corrected comparison binary listed above. Raw events,
transcripts, paired metrics, and build records remain in the private evaluation
lab. Estimated audio cost was $0.00642, not invoice spend.

## Remaining limitations

- In the ready-connection measurements, approximately 99% of stop delay was
  waiting for xAI's first final text. The final acknowledgement follows almost
  immediately. Separate corrected same-socket probes measured 81–86 ms median
  control round trips but 422–601 ms waiting for final text. They identify wait
  beyond the simple network round trip, not a precise split between internal
  networking, queueing, and model computation.
- All six old/new one-minute transcripts contained five complete passages from
  six artificially repeated inputs. One raw-event diagnostic verified all six
  input blocks were sent and xAI's own stitched response contained five.
  Offline replay through the production assembler retained all five. This is
  a provider omission on that artificial fixture, not proof about natural long
  speech accuracy.
- Mixed-language transcription errors remain. One earlier Faithful cleanup
  sample translated Chinese into English; later samples preserved it. Cleanup
  is unchanged, and that intermittent limitation is not considered resolved.
- Native microphone/paste acceptance and reference listening review remain
  separate from transport success and latency validation.

## Sources

- [xAI speech-to-text protocol and controls](https://docs.x.ai/developers/model-capabilities/audio/speech-to-text)
- [xAI speech-to-text model and region](https://docs.x.ai/developers/models/speech-to-text)
- [xAI regional endpoint availability](https://docs.x.ai/developers/advanced-api-usage/regions)

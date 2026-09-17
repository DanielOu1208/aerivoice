# Compose implementation and benchmark checkpoint

Date: 2026-09-14. This records the initial implementation and subsequent benchmark
rounds. Installation, native/browser UI acceptance, and release are separate gates.

**Latest status: the user approved adopting the latest balanced prompt as
experimental. Source now uses that exact candidate, with expanded style descriptions
and experimental guidance for Compose and custom instructions.** Higher reasoning
is suggested as an option to try, with added latency and unverified reliability gains
clearly stated. Reasoning defaults and saved selections are unchanged. This is a
source adoption, not an installation or deployment; known benchmark failures remain.
Earlier no-adoption decisions below describe prior checkpoints.

## Custom style release update (2026-09-17)

Custom instructions now have their own **Custom (Experimental)** style, based on
Polished cleanup. The editor appears only for Custom, and saved instructions are
excluded from requests in Faithful, Polished, and Compose. Switching styles keeps
the saved text; empty Custom uses the Polished prompt. Earlier benchmark examples
combining custom instructions with Compose describe the previous implementation.
The Compose prompt itself and saved reasoning choices are unchanged.

## Experimental source adoption (2026-09-16)

The user accepted the latest rules-only balanced candidate with experimental
labeling. The JSON prompt matches the benchmark artifact exactly, SHA-256
`ad72988595db5eb57ed2121575f0a5cf4fb9b19cbbf92a8108894dd546f4ef9b`.
Plain-text providers receive the same instructions with a plain-text output envelope.
Faithful and Polished prompt bodies, persistence values, defaults and saved reasoning
levels are unchanged. No additional paid calls were made for this adoption.

The style control now opens a panel with a description and selected-state indicator
for each option. Compose is labeled Experimental. Custom instructions receive the
same experimental guidance; one shared notice is shown when Compose is selected.
The notice recommends trying higher reasoning where supported and explicitly states
its latency cost and unverified reliability benefit. “None (Recommended)” is hidden
when Compose or nonempty custom instructions are active, without changing the level.

Validation: 50 prompt, provider-client and settings-component tests passed on the
final source, including structured/plain output paths and custom-setting composition.
The app built successfully. Read-only review found no blocking defects; the small
warning-scope issue was addressed. `git diff --check` passed. Native preview checks were blocked: the standalone executable was not recognized
by Computer Use, and the packaged preview returned `cgWindowNotFound` twice.
Chooser visuals, native keyboard interaction, installed-app behavior and destination
paste remain unverified. The isolated preview was cleaned up. No installation, commit, push or deployment was performed.

## Shorter balanced-prompt experiment (2026-09-16)

A further 72-call round compared three shorter revisions against current Compose,
then advanced one frozen candidate to 12 new cases against current. Reasoning was
**none**, sampling unchanged. All 72 live calls succeeded; six controlled checks
passed. Source/build and effective prompt hashes were verified.

| Prompt | Screening | Fresh confirmation |
| --- | ---: | ---: |
| Current | 9/12 | 10/12 |
| Balanced rules without examples | 10/12 | 9/12 |
| Balanced rules with examples | 10/12 | Not advanced |
| Compact categorized rules with examples | 10/12 | Not advanced |

The selected balanced prompt preserved all three tested ambiguous-name passages
and applied clear named corrections. It preserved the completed-payment fact in
a fresh deleted-task example that current Compose lost. However, it missed two
list layouts and retained a superseded no-email prohibition on fresh cases.
All new candidates dropped the known background-noise sentence in screening.
The example-heavy variant also emitted control characters instead of quotation
marks once; this was graded as an output-integrity failure.

Fresh cleanup medians were 289 ms balanced versus 310 ms current; slowest calls
393/375 ms. Balanced used about 26% fewer input tokens in that comparison. Samples
are too small for stable speed or rare-error claims. Reviews used shuffled labels
by the primary agent, not independent judges. Each case had one call per prompt;
new examples were frozen before screening and exercise known risk categories.

No overall improvement is established. The evidence points toward making the
boundary between requests for new content and edits to supplied content more
explicit; that remains a proposed next change, not a tested fix. App source and
deployment remain unchanged. Artifacts and detailed error analysis are in
`aerivoice-evals/private/compose-balanced-20260916/`, including `report.md` and
`balanced-system-prompt.txt`.

## Synthesis experiment (2026-09-16)

A further user-authorized prompt experiment tested three combinations of the
original and rewritten prompts, capped at **96 calls**, reasoning **none** and
unchanged provider sampling defaults. Screening compared all three with current
Compose on 12 known-risk cases (48 calls); a frozen hybrid then faced current
Compose on 12 newly written edge cases plus 12 broader regressions (48 calls).
Six controlled checks passed. Live effective prompt hashes and build/source
provenance were verified. There were 95 successful client results and one
10-second network timeout on current Compose, retained without a retry.

| Prompt | Targeted screen | New edge cases | Broader regression cases |
| --- | ---: | ---: | ---: |
| Current | 7/11, plus one timeout | 10/12 | 12/12 |
| Hybrid priorities and request boundary | 12/12 | 11/12 | 9/12 |
| Original with narrower correction rules | 9/12 | Not advanced | Not advanced |
| Copy-first edits | 8/12 | Not advanced | Not advanced |

The hybrid restored dictated-request preservation and retained factual reasons for
removing list items. However, on confirmation it dropped an entire sentence in a
new ambiguous-pronoun case, changed “separate notes” to “preserve notes,” and missed
two list layouts. Conservative alternatives sometimes retained superseded wording.
The hybrid is useful development evidence, but not an established overall winner.

Confirmation cleanup medians were 313 ms current and 310 ms hybrid; slowest
successful calls were 594 ms and 1508 ms. The hybrid had about 65% more input tokens
in that comparison. Timing excludes speech and real insertion; the small samples
do not establish rare-error or tail-latency rates. No billing was retrieved.

Prompts and rubrics were frozen before screening, with primary-agent semantic review
under randomized prompt-hidden labels. The new cases exercise known risks with new
wording; they are not a representative random corpus. The app prompt remains
unchanged; no installation/deployment occurred. The detailed error analysis favors
keeping explicit request boundaries and retained-deletion-reason rules while
reducing duplicate instructions and unnecessary rewriting. Those further refinements
remain proposals, not newly validated improvements.

Private artifacts: `aerivoice-evals/private/compose-synthesis-20260916/`, including
`report.md`, both stage reports, all candidates, and `hybrid-system-prompt.txt`.

## Broader adoption check (2026-09-16)

The user authorized adopting the rewritten prompt provided it did not compromise
other cleanup behavior. A bounded 48-call comparison covered 24 broader existing
regression cases, current versus frozen rewritten prompt, one call each per case,
alternating AB/BA. Reasoning remained **none** and sampling defaults were unchanged.
Two controlled checks passed first; source/build and effective prompt hashes were
verified. All 48 calls succeeded without retries or fallbacks.

| Prompt | Behavior passes | Median cleanup | Slowest cleanup |
| --- | ---: | ---: | ---: |
| Current | 22/24 | 319 ms | 594 ms |
| Rewritten priorities | 19/24 | 311 ms | 566 ms |

The rewrite answered a dictated translation request with a French response asking
for the missing text; current Compose preserved the dictated English request.
It also removed an explicit port prohibition, omitted a requested topic paragraph,
and retained superseded date wording under the frozen rubric. Both prompts dropped
a clarification about version numbers. Current Compose additionally used numbered
lines where unordered bullets were required. These are observed outcomes, not
estimated long-run error rates; there was only one matched pair per case.

The translation-response failure violates the user's no-other-compromise condition.
**Do not adopt this exact candidate; the app prompt remains unchanged.** The prior
targeted improvement is real on that sample, but did not carry through this wider
check. Timing gives no evidence of a material latency penalty here; provider-only
medians were 45 ms current and 40 ms rewritten. These measurements exclude speech
and desktop insertion. Review used shuffled prompt labels by the primary agent,
not an independent reviewer. No installation or deployment occurred.

Full outputs, frozen rubrics, prompt hashes and token usage are retained privately
in `aerivoice-evals/private/compose-regression-20260916/`. This check reused existing
cases and does not constitute fresh confirmation or establish rare-error rates.

## Targeted prompt-only comparison (2026-09-15)

A user-requested short comparison retested only the eight cases with defined
behavior failures. Current Compose, an appended-safeguards variant, and a rewritten
priority-based variant each ran twice per case: **48 cleanup calls**, all with
Cerebras `qwen-3.8-27b`, reasoning **none**, and unchanged provider sampling defaults.
Six controlled checks passed first; executable/source provenance and effective
prompt hashes were verified. All 48 calls succeeded without fallback or retry.

| Prompt | Behavior passes | Cases passing both trials | Median cleanup | Slowest cleanup |
| --- | ---: | ---: | ---: | ---: |
| Current | 9/16 | 4/8 | 303 ms | 347 ms |
| Appended safeguards | 10/16 | 5/8 | 335 ms | 468 ms |
| Rewritten priorities | 13/16 | 6/8 | 330 ms | 523 ms |

The rewritten prompt is the most promising development candidate, but it still
renamed an ambiguous person in both trials and dropped the meaningful background-
noise sentence in one trial. All three prompts failed both ambiguous-reference
trials. Separate translation quality notes include duplicated wording; behavioral
passes do not imply polished wording. Scores use the unchanged case rubrics and
primary-agent review with randomized output labels, not independent blind review.

This is a comparison on known failing development cases, not fresh confirmation.
Two trials per case cannot establish reliability. Request ordering rotates and
reverses for matched comparison; reported cleanup timing excludes speech and
actual insertion. Median provider-only times were 37/59/45 ms respectively.
No reasoning escalation, app prompt change, installation, or deployment occurred.
Whole-message retraction still requires a separate successful-no-insertion contract.
Keep Compose undeployed. Full prompts, reviewed outputs, token counts, and hashes
are retained privately in `aerivoice-evals/private/compose-targeted-20260915/`.

## Additional edge cases (2026-09-14)

A user-requested follow-up exercised the unchanged production Compose prompt on
20 new cases twice each: 40 additional cleanup-only calls, using the same direct
Cerebras model with reasoning disabled. Three cases included custom instructions.
The existing Release executable and production sources were verified against the
build record; a controlled check confirmed the expected prompt fingerprint.

- 28 of 38 outputs passed the prewritten behavior rubrics; 10 failed. Eleven of
  the 19 behavior cases passed both trials.
- Two additional whole-message-retraction trials were exploratory. Both received
  HTTP 200 but failed cleanup-client validation. The rejected response body was
  not retained, so empty versus malformed content is not established. The app's
  existing raw-text fallback would apply to cleanup failures; that consequence
  comes from code inspection, not a pipeline run in this follow-up.
- Serious failures included collapsing a quoted-punctuation message to a single
  punctuation mark, choosing different people in an ambiguous name correction,
  retaining a superseded negative instruction, and dropping meaningful content.
- Custom translation changed a protected name in one trial; a custom spelling
  replacement was ignored in another. One formatted list retained its layout cue.
- Multi-field corrections, separate lists, technical literals, reported prompt
  injection text, arithmetic questions, long late corrections, Chinese examples,
  French/English mixing and the single-paragraph custom setting passed both trials.
- Successful-response cleanup median was approximately 316 ms and p95 849 ms.
  These standalone timings exclude failed responses and are not a matched speed
  comparison with Polished.

Full synthetic inputs, outputs, rubrics, provenance and reviews remain private in
the eval lab's `private/compose-edge-20260914/` directory. No production prompt or
app code was changed during this round. Literal-content preservation, ambiguous
corrections, custom-setting consistency and whole-message retraction need further
work before a deployment candidate is accepted.

## Result

Compose is an opt-in third cleanup style. It formats supplied lists and paragraphs,
resolves corrections within the current recording, and improves phrasing while
preserving details. It uses the selected cleanup provider and the existing single
cleanup request. Faithful, Polished, their defaults, and the insertion path are
unchanged. Custom settings retain the Compose rules and existing setting precedence.

Seven Compose prompt candidates were evaluated against the existing Polished
prompt. The selected candidate combines explicit restrictions against answering
dictated requests with examples of formatting and corrections. Formatting is
limited to content the speaker actually supplied. A request to generate a list
must remain a dictated request when its items were not supplied.

The first two finalists were rejected: both sometimes generated answers to
dictated requests in unseen cases. A user-authorized, bounded follow-up tested
three stricter candidates. The winner passed all 36 fresh confirmation outputs
and all 18 Compose pipeline outputs on the predefined behavior checks. These are
task-specific fixture results, not a general transcription accuracy percentage.

## Experiment

The private `aerivoice-evals` lab ran the production-linked Release
`AeriVoiceEvalHarness`. All live cleanup used direct Cerebras `qwen-3.8-27b` with
reasoning `none`; model sampling defaults were retained. No provider switch or
fine-tuning was introduced. The original cap was extended with explicit user
authorization after the initial confirmation failed.

| Stage | Design | Cleanup calls |
| --- | --- | ---: |
| Initial screening | 24 development cases × Polished and four Compose prompts | 120 |
| Initial confirmation | Two finalists versus Polished; 12 unseen cases, three pairs each | 144 |
| Targeted follow-up | Three revised prompts × 12 regression cases × two repetitions | 72 |
| Fresh confirmation | Frozen winner versus Polished; 12 new cases, three pairs each | 72 |
| Production pipeline | Six fixed audio fixtures; Compose versus Polished, three pairs each | 36 |
| **Total** | **444 successful cleanup calls; no failures, fallbacks or cancellations** | **444** |

Confirmation comparisons alternated A/B then B/A in independent processes, using
the lab's comparison command. Screening rotated candidate order. A Debug build
overlapped part of initial screening, so those timings were exploratory; final
confirmation ran without a concurrent build. The pipeline used identical local
Samantha speech fixtures at rate 180, 48 kHz mono PCM, with 200 ms leading and
trailing silence. It streamed them to Soniox, then used the production cleanup
path. Sound cues were disabled and preparation was false in both groups.

The primary agent reviewed actual outputs against rubrics written before each
stage. Checks covered lists, paragraph/line cues, immediate and earlier
corrections, quoted/discussed cues, ordinary contrast, requests to another AI,
names, quantities, uncertainty, English, Traditional/Simplified Chinese and
mixed-language speech. Equivalent wording and punctuation were accepted;
literal word-error scores were not used as a proxy for cleanup quality.

## Final measurements

| Fresh text-only confirmation | Polished | Compose |
| --- | ---: | ---: |
| Successful samples | 36 | 36 |
| Met the requested behavior rubric | 14/36 | 36/36 |
| Median cleanup | 317 ms | 321 ms |
| p95 cleanup | 853 ms | 598 ms |

| Soniox → production cleanup → test receiver | Polished | Compose |
| --- | ---: | ---: |
| Successful samples | 18 | 18 |
| Met the requested behavior rubric | 6/18 | 18/18 |
| Median cleanup | 238 ms | 315 ms |
| p95 cleanup | 641 ms | 444 ms |
| Median STT finalization | 110 ms | 136 ms |
| Median stop to test receiver | 431 ms | 463 ms |
| p95 stop to test receiver | 754 ms | 551 ms |

The score difference largely reflects the requested formatting and correction
features, which Polished does not consistently provide. The pipeline's median
stop-to-output difference was approximately 32 ms. Samples are small, p95 uses
nearest rank, and provider/network variability prevents treating lower observed
tail times as a speed guarantee. Component medians should not be added together.

Pipeline raw transcripts were reviewed separately; they preserved fixture meaning
with number-rendering and punctuation differences. No microphone, hardware-audio,
desktop-paste consumption, or live-user latency claim follows from this harness.

## Reproducibility and privacy

The JSON Compose prompt fingerprint is
`6584fbaeb933f17fb1e7e20ac59a4b050a619ad61affd023bda3354c2c7e2be1`.
The final Release harness executable SHA-256 is
`3d395ba27c789f03a5ec4498ec8ca74574760b5c2374da2ad351397692dcc289`.
All 36 pipeline runs used that executable and verified the expected effective
prompt fingerprint. Pipeline scenarios used Compose directly, without a prompt
override. The build record reports stable source during compilation.

The private lab's `private/compose-20260914/` directory retains frozen prompts,
fixture rubrics/audio hashes, scenarios, build provenance, every raw run and
report, semantic reviews, and stage summaries. `experiment.py`, `followup.py`,
and `pipeline.py` drive the bounded stages through the existing controller and
refuse silent paid repeats of a started stage. The lab controller now accepts
`Compose` scenarios. Detailed artifacts remain private and ignored by Git.
Credentials used the lab's inherited pipe; none were written into scenarios,
arguments, or reports. Production diagnostics remain content-free.

## Checks and remaining gates

- Full Swift suite: 421 passed, three opt-in live benchmarks skipped. After the
  winning prompt was installed, 48 focused prompt/provider tests passed; a final
  plain-text envelope adjustment passed 16 focused tests. These repeated subsets
  are not additional independent coverage.
- Eval controller plus controlled harness integration: 47 passed, no skips.
- Tests cover persistence/defaults, recording-start settings capture, Compose with
  custom settings, JSON/plain-text envelopes, multiline preservation and expansion
  budgets; the full suite covers existing cancellation, offline and fallback paths.
- Read-only code review found no blocking implementation issues. Diff whitespace
  checks passed.
- One targeted winner output inserted an unnecessary line break between related
  clauses while retaining the literal cue words. This remains a known formatting
  limitation. Other provider/model output quality and live custom-instruction
  combinations were not benchmarked.
- Native settings acceptance is unverified: CUA returned `cgWindowNotFound` for
  isolated Debug and Release QA apps. TextEdit acceptance is unverified after
  CUA returned `timeoutReached` before document creation. Temporary QA processes
  were stopped; installed AeriVoice was not replaced or restarted.
- Browser clipboard acceptance is unverified: fixture setup failed on the browser
  new-tab page before paste. Its test space was closed and could not be resumed.
- **Not installed, committed, pushed, or released.** Complete native settings and
  destination-field paste acceptance before deployment, then obtain deployment
  authorization separately.

# Safe cross-app text insertion

## Contract

- Capture the frontmost PID synchronously when dictation stops; acquire the AX
  focused-element identity on a background task while transcription finishes.
  Revalidate that same element and editor before mutating. Do not activate apps,
  move focus, set AXValue, or substitute a later field when capture fails.
- Prefer positively settable AXSelectedText. Success means that the app accepted
  that attribute mutation, not a guarantee of durable application storage.
- Otherwise prefer an enabled standard Paste menu command, then a PID-targeted
  Command-V only with positive editable evidence. A discovered disabled Paste
  command is not bypassed. Do not retry an attempted mutation/action on timeout:
  it may already have happened.
- A paste request is **unconfirmed**, including a successful AXPress. Keep its
  transcript on the clipboard; never restore old contents on a timer. This also
  removes lossy snapshotting of rich, lazy and promised clipboard representations.
- One active transaction per pasteboard, across service instances. Defer writing
  until final validation; recheck marker and change count at dispatch. If the user
  changes the clipboard during preparation, preserve their copy and report failure
  rather than claim the transcript was copied. Cancellation before commit has no
  clipboard side effect; cancellation after commit leaves the transcript there.

## Accessibility bounds

Capture has a 3.25-second cooperative budget, including up to twelve 250 ms
activation waits. Insertion has a separate 750 ms budget. Every AX query/action
uses the smaller of its per-call timeout and the remaining budget. Failure to set
an AX timeout rejects the operation. No timeout-racing detached task can paste
later. These are cooperative messaging deadlines, not real-time OS guarantees.
Final Paste validation, clipboard commit and dispatch run synchronously on MainActor
within the remaining insertion budget, so there is no actor hop between the last
target check and the action. This can briefly delay UI work for a slow AX target;
capture, preparation and direct selected-text insertion stay off the main actor.

A text role or readable selection attributes alone do not prove editability.
Require settable selected text, or a text role with settable value/positive
editable evidence. Honor disabled/read-only flags. Read AX metadata, not field
contents. Check secure status all the way to the target application's root;
missing parents, cycles, unknown status and depth exhaustion reject insertion.
Missing AXSubrole is permitted because ordinary AX containers omit it; this is
not a guarantee against third-party apps that conceal secure-field semantics.

Electron's documented AXManualAccessibility flag is enabled only when settable.
A generic application-role read also activates Chromium's native accessibility.
Recovery may wait for the *same* captured focus to become usable. If there is no
initial focus, activation can help subsequent attempts, but this result copies
rather than guessing a new stop-time field. No undocumented AXEnhancedUserInterface
switch or app-name exception table is used.

## Remaining platform limits

macOS has no atomic focus/clipboard compare-and-paste. Revalidation narrows but
cannot eliminate a change between the last check and the target handling the
request. A user copy or later dictation can still replace an unconsumed paste.
The warning is intentional; do not interpret insertionUnconfirmed timing as insertion
latency. Returning to the same AX field before final validation is permitted;
this is an identity snapshot, not continuous focus-history monitoring.

## Acceptance matrix

Use disposable documents/fields only; never submit a message. Exercise TextEdit,
Chrome/Safari inputs and contenteditable, and an Electron editor (VS Code or
Discord scratch field). Verify selected-text replacement, Unicode/newlines,
read-only/secure rejection, changed app/field, cancellation, user copy during
preparation, and a busy target. Unit tests use private pasteboards and do not
paste into the active application.

## Validation status (2026-09-06)

Automated tests cover private-board ownership and overlapping transactions,
clipboard fidelity on direct insertion, unconfirmed delivery without timer restore,
changed focus at the final commit boundary, cancellation, ancestry failures,
read-only controls, delayed activation, AX retry/deadline gates, mutation error
classification, and distinct persisted unconfirmed outcomes. Local validation:
**240 passed** on the isolated paste-only staged snapshot. The complete development
working tree (including separate cleanup/benchmark work) passed **254 tests** with
**2 opt-in provider benchmarks skipped**, and its Release build passed.
Formatting lint passes for the insertion/integration files except two pre-existing
model-case naming warnings in Models.swift. The Release build also retains an
unrelated actor-isolation warning at AppDelegate.swift:87.

Live application acceptance is **deferred by the user**, not passed. The installed
CuaDriver 0.20.0 daemon remained unavailable after one supported app-launch attempt.
An exact-source Swift 6 harness compiled and reported AX_TRUST=true; it did not
perform insertion or interact with app content. No target apps/documents or privacy
settings were changed. Repeat the scratch matrix after computer control is restored.

## Primary references

- https://developer.apple.com/documentation/applicationservices/kaxselectedtextattribute
- https://developer.apple.com/documentation/applicationservices/1460434-axuielementsetattributevalue
- https://developer.apple.com/documentation/applicationservices/1462091-axuielementperformaction
- https://developer.apple.com/documentation/coregraphics/cgevent/posttopid(_:)
- https://developer.apple.com/documentation/appkit/nspasteboard/changecount
- https://www.electronjs.org/docs/latest/tutorial/accessibility
- https://github.com/electron/electron/blob/main/shell/browser/mac/electron_application.mm

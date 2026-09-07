# Cross-app Paste

## Contract

AeriVoice uses the same PID-targeted Command-V operation for every eligible app.
It does not write AXSelectedText or AXValue, search menus, maintain app-name
exceptions, move focus, or activate a destination. Each transaction can dispatch
at most once. There is no automatic retry after posting an event.

Recording stops immediately. A bounded synchronous capture then pins the
frontmost app, window, and focused accessibility element at the stop gesture.
The same identities and the editor's security ancestry are checked again just
before Paste. A failed capture never substitutes a later field.

Standard text-field, text-area, and combo-box roles are eligible for normal
Paste without requiring accessibility mutation support. This distinction matters
for terminals such as Ghostty, which expose text areas but do not allow AX text
writes. Custom editors need an explicit editable flag and selection metadata on
the same element. Explicit disabled/read-only flags reject the target, including
a read-only focused child beneath an editable ancestor.

Secure-field metadata is checked through every ancestor to the application root.
Missing parents, unknown query results, cycles, and depth exhaustion prevent
Paste. Missing/unsupported AXSubrole is accepted because ordinary controls and
containers omit it; this cannot guarantee safety when a third-party app conceals
its secure-field semantics. The global secure-keyboard-input state is also
checked at capture and immediately before dispatch, always on MainActor because
Carbon's query is not thread safe. AeriVoice never toggles secure input.

Secure fields still finish transcription and cleanup. The result is copied with
a warning to paste manually if intended. Unsupported, unavailable, changed,
read-only, and blocked-shortcut targets likewise copy with a specific reason.
Physical Command/Control/Option/Shift keys are allowed a bounded time to release;
AeriVoice does not synthesize releases for keys the user is holding.

## Clipboard and result reporting

The clipboard change count is captured when dictation stops. Copies the user
makes during cleanup or insertion preparation are preserved. If the clipboard
has changed, AeriVoice reports that it could not paste or copy, rather than
overwriting the new copy or falsely claiming that the transcript is available.

One transaction per pasteboard is allowed across service instances. Clipboard
write, ownership verification, and final dispatch run synchronously on MainActor.
A private owner marker and change count guard the write. Cancellation before
commit does not change the clipboard; after commit, the transcript is left there.
The clipboard is never restored on a timer, since an app may consume Paste later.

The UI reports **Paste sent** after dispatch. It does not claim confirmed insertion:
CGEvent.postToPid returns no destination-consumption acknowledgment. Benchmarks
record `pasteSent` and specific copy-rejection categories without field contents.
Legacy `inserted` and `insertionUnconfirmed` records remain decodable.

## Bounds and platform limits

Stop-time identity capture has a 350 ms cooperative budget. Accessibility metadata
recovery has a separate 3.25-second budget, with up to twelve 250 ms waits only
for unavailable metadata; definite policy rejections do not wait or activate
accessibility. Final insertion has a 750 ms budget, including modifier release.
Each synchronous AX request receives the smaller of its own timeout and the
remaining budget. Cancellation and expiry are checked again after clipboard
access, immediately before dispatch. These are cooperative messaging bounds,
not real-time OS guarantees. No detached timeout task can paste later.

Electron's documented AXManualAccessibility flag is enabled only when settable.
A generic application-role read also activates Chromium's native accessibility.
Recovery can make the same captured focus usable. If no initial focus identity
exists, activation may help the next dictation but this one copies. No
AXEnhancedUserInterface switch is used.

macOS has no atomic focus/clipboard compare-and-paste operation. A destination
can change after the last check but before handling the event. Caret movement
within the same field is allowed; returning to that same field before validation
is also allowed. A user copy or later dictation can replace a still-unconsumed
paste. Missing read-only/security metadata limits what can be recognized.

AeriVoice sends no Return key. Pasted newlines can still trigger behavior in a
terminal or another destination according to that app's Paste handling. Live
terminal tests must therefore use a disposable input receiver, never a shell.

## Validation (2026-09-06)

The full working-tree suite passed 248 tests with two opt-in provider benchmarks
skipped. Focused service/coordinator checks passed after the review fixes, and
service tests passed after the final clipboard-ownership recheck. Coverage
includes stop-audio ordering, same-target capture, final focus rejection, secure
and read-only ancestry, metadata recovery, clipboard changes during cleanup and
validation, empty clipboard, once-only dispatch, cancellation, concurrent
transactions, and separate result/benchmark categories.

A separate checkout containing only the staged insertion changes passed all
87 focused insertion, coordinator, and latency-recording tests before commit.

The signed distribution Release build `2026090603` passed. It retains a pre-existing
actor-isolation warning in AppDelegate.swift and the standard AppIntents metadata
warning. Native live checks passed for Dia textarea and contenteditable with exact Unicode
and newline replacement. Its password fixture returned `copied(secureInput)` and
remained unchanged. The read-only textarea exposed no explicit read-only flag:
it received one Paste request, stayed unchanged, and reported `pasteSent`. This
is a known metadata limitation, not a passed read-only-detection check. Treating
all non-settable AX text areas as read-only would reject working terminals again.
TextEdit and VS Code also passed exact two-line Unicode replacement. TextEdit's
first two attempts were blocked before dispatch because VS Code was frontmost;
after explicitly activating the disposable TextEdit window, its check passed.

Ghostty's receiver was launched, but Computer Use refused access to
`com.mitchellh.ghostty` for safety reasons. No Paste probe was dispatched into it,
and the restriction was not bypassed. Ghostty delivery remains unverified; its
previous AX-writability rejection is removed and covered by text-role policy tests.
These native checks exercised the exact production insertion code with a known
transcript, not live microphone/provider transcription.

Build `2026090603` was installed and restarted from `/Applications/AeriVoice.app`
on MBP16. Its installed binary matched the signed build SHA-256
`940e8f73016116360e5e6a5ba9c8b8af963c085df1073364dbc4361edd508033`;
the running process path and build were verified separately. The previous
`2026090602` bundle is retained in
`~/Library/Application Support/AeriVoice/Backups/AeriVoice-2026090602-before-shared-paste.app`.
No settings, credentials, or privacy permissions were changed.

## Primary references

- https://developer.apple.com/documentation/coregraphics/cgevent/posttopid(_:)
- https://developer.apple.com/documentation/appkit/nspasteboard/changecount
- https://developer.apple.com/documentation/applicationservices/kaxsecuretextfieldsubrole
- https://www.electronjs.org/docs/latest/tutorial/accessibility
- https://github.com/electron/electron/blob/main/shell/browser/mac/electron_application.mm
- https://tryvoiceink.com/docs/clipboard-issues

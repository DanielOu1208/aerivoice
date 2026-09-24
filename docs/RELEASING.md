# Releasing AeriVoice

Releases are built, signed, and notarized locally. Signing identities and
notary credentials must never be stored in GitHub.

## One-time setup

1. Create a **Developer ID Application** certificate in the Apple Developer
   account and install its certificate plus private key in the login Keychain.
2. Create an app-specific password or App Store Connect API key accepted by
   `notarytool`.
3. Store the credentials in Keychain:

   ```sh
   xcrun notarytool store-credentials AeriVoiceNotary
   ```

4. Confirm the identity is visible:

   ```sh
   security find-identity -v -p codesigning
   ```

## Build a candidate

Start from a clean release commit that passed CI. The tag version may include a
prerelease suffix; the app's marketing version remains the numeric prefix.
Configure the Sparkle environment described below before running this command.
Set up the pinned DMG packaging environment below as well.

```sh
export AERIVOICE_DEVELOPMENT_TEAM='YOUR_TEAM_ID'
export AERIVOICE_SIGNING_IDENTITY='Developer ID Application: Your Name (YOUR_TEAM_ID)'
export AERIVOICE_NOTARY_PROFILE='AeriVoiceNotary'
./scripts/release-local.sh 0.1.0-beta.1 1
```

The command writes the signed DMG, checksum, and dSYM archive to
`dist/v0.1.0-beta.1/`. It stops on a signing, notarization, stapling, Gatekeeper,
version, architecture, or checksum failure.

## Release gate

Before publishing:

- Run the full tests, static analysis, and unsigned Release build from a fresh
  clone.
- Exercise 96 kHz → 48 kHz → 96 kHz audio-route changes across repeated
  recordings.
- Install the downloaded, quarantined DMG in a clean user environment and
  complete onboarding.
- Verify TextEdit and Discord/Electron insertion, cancellation, launch at login,
  and the default Gemini 3.5 Flash Lite / Minimal cleanup route.
- Confirm screenshots and logs contain no credentials or transcript content.
- Compare the downloaded DMG checksum with the locally produced checksum.

Create a draft prerelease first. Changing repository visibility, enabling the
public security settings, pushing the release tag, and publishing the release
are separate explicit approval steps.

## Branded installation window

Both release and isolated updater QA images use `scripts/build-dmg.py`. The helper
packages an existing app with a light Finder background, fixed icon placement,
and an Applications shortcut. It does not open Finder, install an app, sign, or
publish anything. Window geometry lives in `scripts/dmg/layout.json`; the native
Swift renderer beside it generates 1× and 2× artwork, combined into a Retina TIFF.
The 640×420 size describes the Finder window bounds, including its title bar.

Install the exact packaging dependencies once in a dedicated Python 3.11+ venv:

```sh
python3 -m venv "$HOME/Library/Caches/AeriVoice/dmg-tools"
export AERIVOICE_DMG_PYTHON="$HOME/Library/Caches/AeriVoice/dmg-tools/bin/python"
"$AERIVOICE_DMG_PYTHON" -m pip install --require-hashes --only-binary=:all: \
  -r scripts/dmg/requirements.txt
"$AERIVOICE_DMG_PYTHON" scripts/build-dmg.py check
```

The build never installs dependencies automatically. The release script accepts
`AERIVOICE_DMG_PYTHON`; the QA fixture builder also accepts `--dmg-python` (use this
explicit flag with `aqua-run`, which does not inherit arbitrary environment).

Preview the window using any existing local app build and a fresh output path:

```sh
"$AERIVOICE_DMG_PYTHON" scripts/build-dmg.py build \
  --app /path/to/AeriVoice.app --output /tmp/AeriVoice-preview.dmg
"$AERIVOICE_DMG_PYTHON" scripts/test-dmg-layout.py \
  --app /path/to/AeriVoice.app --dmg /tmp/AeriVoice-preview.dmg
open /tmp/AeriVoice-preview.dmg
```

Preview DMGs are unsigned. A release performs layout generation before DMG
signing, notarization, stapling, checksums, and Sparkle feed generation. Never edit
an already signed image. Packaging verifies copied app bytes, permissions, and
symlinks, then verifies a signed app again after all layout changes. Do not set
Finder flags on the app bundle (including hiding its extension): this adds
`com.apple.FinderInfo`, which fails strict code-signature validation. Existing
outputs, including symlinks, are rejected.

Before accepting artwork, inspect a fresh mount in light and dark appearance:
heading, instruction, both native icons and filenames, arrow, and footer must be
readable and unclipped. Confirm the Applications shortcut opens `/Applications`.
Use an isolated QA app for upgrade testing; do not replace the production install
with a preview. CI builds and inspects an unsigned DMG after its Release build.

## Signed in-app updates (Sparkle 2.10.0)

The only public feed is `https://aerivoice.app/updates/appcast.xml`. Beta and stable
releases share this track. `CFBundleVersion` is a positive integer that must
increase for every published build, even if its marketing version does not
change. `CFBundleShortVersionString` stays numeric; `AeriVoiceReleaseVersion`
and the feed display the full release label, such as `0.1.0-beta.12`.

Generate the Ed25519 key once with the pinned Sparkle tools, using the dedicated
Keychain account `com.danielou.AeriVoice.sparkle`. Preserve secure recovery access
to that Keychain; never put private keys in the repository, command arguments,
logs, or CI. `generate_keys --account com.danielou.AeriVoice.sparkle -p` prints
only the public key. The release script embeds that public key using
`AERIVOICE_UPDATE_PUBLIC_KEY` and checks it against the configured signing account.
Do not casually regenerate or change this key: existing installations trust it.

Before running the candidate command above, also configure:

```sh
export AERIVOICE_SPARKLE_BIN='/path/to/pinned/Sparkle/bin'
export AERIVOICE_SPARKLE_ACCOUNT='com.danielou.AeriVoice.sparkle'
export AERIVOICE_RELEASE_NOTES='/absolute/path/to/release-notes.txt'
export AERIVOICE_PREVIOUS_APPCAST='/absolute/path/to/published-appcast.xml'
```

Use the exact currently published feed as history, obtained over HTTPS. The
script verifies its signature before retaining its entries. For the first-ever
feed only, omit `AERIVOICE_PREVIOUS_APPCAST` and set
`AERIVOICE_INITIAL_FEED=1`. This flag is not a way to reset build history. Keep an
independent record of the highest build ever published, including withdrawn
builds, and choose a larger number for each subsequent release.

The candidate workflow archives Release, then uses `xcodebuild -exportArchive`
with Developer ID export signing so Sparkle's nested helpers receive the proper
signatures. It checks arm64, bundle versions, Developer ID/team, hardened runtime,
audio-input entitlement, absence of debugger entitlement, and deep code-signature
validity before notarizing and stapling the app and DMG. After the final DMG bytes
are fixed, `generate-update-feed.py` runs `generate_appcast --maximum-deltas 0
--embed-release-notes`, verifies the archive signature, adds the human-readable
release label and arm64 requirement, retains validated history, and signs and
verifies the complete feed with `sign_update`. Plain-text notes must be `.txt`.
There are no delta updates or external release-note requests.

`dist/vVERSION/appcast.xml` is a local signed candidate; candidate preparation
requires no public release and does not change the website. The generator fails
on missing keys/configuration, mismatched app metadata, duplicate/non-increasing
builds, duplicate release labels, unexpected URLs, or invalid system/architecture
metadata. Existing output is never overwritten. Synthetic validation tests run without private keys:

```sh
python3 -m unittest discover -s scripts/tests -p 'test_update_feed.py'
```

## Publish assets first, feed last

1. Complete the release gates above and test the updater using a separate local
   QA build/feed. Check the signed/notarized production artifact separately.
2. Publish the version-specific GitHub release and immutable DMG asset at
   `https://github.com/DanielOu1208/aerivoice/releases/download/vVERSION/AeriVoice-vVERSION-arm64.dmg`.
   Publish its checksum and symbols. Never replace an asset already advertised in
   the feed; issue a new release label and a higher build instead.
3. Download the public asset and compare its SHA-256 and byte length to the local
   artifact; verify its Sparkle archive signature, Developer ID signature,
   notarization, and stapling. A draft/private asset is not available to users.
4. Copy the exact generated `appcast.xml` bytes into the website repository at
   `public/updates/appcast.xml`, creating `public/updates/` if necessary. Do not
   create a placeholder feed before a real signed release exists. Publish this
   website change only after the public asset passes verification.
5. Fetch the public feed and compare its SHA-256 with the local signed feed; run
   `sign_update --account com.danielou.AeriVoice.sparkle --verify downloaded-appcast.xml`.
   Verify HTTP 200, XML content type, and `Cache-Control: public, max-age=300,
   must-revalidate`. Confirm a previous installed updater build offers the update
   and completes installation with settings intact. CDN caches may take up to
   five minutes to expire.

Do not format, minify, rewrite, or otherwise edit the feed after signing. Any
change needs a new signature. Website deployment must copy this static file
unchanged. Users on versions without Sparkle need one final manual installation
of an updater-enabled release.

To withdraw a bad release, remove its item from a local copy of the feed, sign
and verify the modified feed, then publish those exact bytes. Retain the highest
published build in release records. Ship a corrected release with a higher build;
withdrawal does not uninstall an already installed release, and the updater must
not force a downgrade. Never weaken signature requirements to recover a release.

## Repeatable isolated local updater QA

`scripts/test-updater-local.py` prepares two builds of **AeriVoice Update QA**
(`com.danielou.AeriVoice.UpdaterQA`). It does not install or launch them. It uses
the separate Keychain account `com.danielou.AeriVoice.UpdaterQA.sparkle` and fixed
QA public key `Xyw1LV9Tqgn9gq67pLcOKbZoUsrM5DZF+S+tnLQETaM=`. The account must
already exist; the script never creates a key. QA preferences, credentials, and
storage isolation are supplied by the app's `AERIVOICE_UPDATER_QA` implementation.
Do not use the production app or its installation path for this procedure.

Run signing inside the logged-in desktop session with `aqua-run`. These commands
use the same Developer ID identity/team environment values as the release workflow,
but pass them explicitly because `aqua-run` does not inherit arbitrary variables:

```sh
/Users/danielou/.local/bin/aqua-run python3 scripts/test-updater-local.py build \
  --output /tmp/aerivoice-updater-qa-final \
  --team "$AERIVOICE_DEVELOPMENT_TEAM" \
  --identity "$AERIVOICE_SIGNING_IDENTITY"
```

The default uses Release optimization, QA-only compilation conditions, Developer
ID archive/export signing, app and DMG notarization/stapling, and deep signature
verification. Builds A and B default to 900001 and 900002; override both with
`--build-a` and `--build-b` when repeating with newer installed QA builds. A fresh
output directory is required for every attempt. The build records its base commit, dirty-worktree flags at start/end, and
notarization status in `fixture.json`. Dirty builds embed a `-dirty` source-revision
suffix; the base commit alone does not identify their source contents. Source may be dirty for local QA; this is
separate from the production script's mandatory clean checkout.

For faster iteration only, append `--configuration Debug --no-notary`. These
fixtures remain Developer ID signed but **are not final acceptance evidence**.
Every final acceptance build must be regenerated without `--no-notary`. The
notary profile defaults to `AeriVoiceNotary`; Sparkle tools and package checkout
default to `/tmp/aerivoice-updater-packages`. The build generates a temporary
QA-specific Info.plist permitting HTTP for local testing; it never changes the
production Info.plist or its transport policy.

The output contains exported A/B apps under `A/export/` and `B/export/`, signed
DMGs and plain-text notes under `public/`, and these feed fixtures:

- `valid.xml`: signed feed containing both builds and valid DMG signatures.
- `invalid-feed-signature.xml`: content changed after signing; the client must
  reject the feed before offering an update.
- `invalid-archive-signature.xml`: correctly signed feed whose B enclosure has an
  invalid EdDSA archive signature. Sparkle may first accept the DMG's Developer ID
  signature as a key-rotation fallback, extract it, and then reject the unchanged
  app key against the invalid EdDSA signature. This is not a pre-extraction test.
- `invalid-archive-both-signatures.xml`: correctly signed feed pointing to a
  separate copy of B's DMG with modified payload bytes and an invalid
  EdDSA signature. This must fail before extraction. The original valid B DMG is
  never modified.

The script verifies both valid archive signatures, verifies the valid and
invalid-archive feeds, and confirms that both tampered-DMG code verification and
the deliberately invalid EdDSA signatures
fail verification. No private key material is printed or written by the script.
The server serves only the public fixture directory, without caching:

```sh
python3 scripts/test-updater-local.py serve --output /tmp/aerivoice-updater-qa-final
```

This foreground server binds only to `127.0.0.1:8769`. Both apps use
`http://127.0.0.1:8769/appcast.xml`; the default case is valid. In a second terminal,
select a case without editing or re-signing its bytes:

```sh
python3 scripts/test-updater-local.py select \
  --output /tmp/aerivoice-updater-qa-final --case invalid-feed-signature
python3 scripts/test-updater-local.py select \
  --output /tmp/aerivoice-updater-qa-final --case invalid-archive-signature
python3 scripts/test-updater-local.py select \
  --output /tmp/aerivoice-updater-qa-final --case invalid-archive-both-signatures
python3 scripts/test-updater-local.py select \
  --output /tmp/aerivoice-updater-qa-final --case valid
```

Install/launch only when the separately approved native test plan calls for it.
Start each upgrade case from exported build A in a separate QA installation path.
Expected acceptance includes A → B replacement/relaunch, retained QA settings,
unchanged production storage, safe cancellation, rejection of all three invalid
signature cases, and no update checks/downloads while Offline mode is active.
Close the server with Control-C after testing. Never publish these QA feeds or
assets. Offline transformation tests require no signing or server:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s scripts/tests -p 'test_updater_local.py'
```

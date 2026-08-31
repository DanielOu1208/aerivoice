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

#!/bin/bash

set -euo pipefail
umask 077

usage() {
  echo "Usage: $0 <release-version> <build-number>" >&2
  echo "Example: $0 0.1.0-beta.1 1" >&2
}

release_version="${1:-}"
build_number="${2:-}"
if [[ -z "$release_version" || -z "$build_number" ]]; then
  usage
  exit 64
fi
if [[ ! "$release_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]]; then
  echo "Release version must look like 0.1.0 or 0.1.0-beta.1." >&2
  exit 64
fi
if [[ ! "$build_number" =~ ^[1-9][0-9]*$ ]]; then
  echo "Build number must be a positive integer." >&2
  exit 64
fi

development_team="${AERIVOICE_DEVELOPMENT_TEAM:-}"
signing_identity="${AERIVOICE_SIGNING_IDENTITY:-}"
notary_profile="${AERIVOICE_NOTARY_PROFILE:-AeriVoiceNotary}"
if [[ -z "$development_team" || -z "$signing_identity" ]]; then
  echo "AERIVOICE_DEVELOPMENT_TEAM and AERIVOICE_SIGNING_IDENTITY are required." >&2
  exit 64
fi
if [[ "$signing_identity" != "Developer ID Application: "* ]]; then
  echo "AERIVOICE_SIGNING_IDENTITY must be a Developer ID Application identity." >&2
  exit 64
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_root="$(cd "$script_dir/.." && pwd)"
cd "$repository_root"

if [[ -n "$(git status --porcelain)" ]]; then
  echo "Release builds require a clean working tree." >&2
  exit 1
fi
if ! security find-identity -v -p codesigning | grep -Fq "\"$signing_identity\""; then
  echo "The requested Developer ID Application identity is not installed." >&2
  exit 1
fi

sparkle_bin="${AERIVOICE_SPARKLE_BIN:-}"
dmg_python="${AERIVOICE_DMG_PYTHON:-python3}"
"$dmg_python" "$script_dir/build-dmg.py" check
sparkle_account="${AERIVOICE_SPARKLE_ACCOUNT:-com.danielou.AeriVoice.sparkle}"
release_notes="${AERIVOICE_RELEASE_NOTES:-}"
previous_appcast="${AERIVOICE_PREVIOUS_APPCAST:-}"
initial_feed="${AERIVOICE_INITIAL_FEED:-0}"
if [[ ! -x "$sparkle_bin/generate_appcast" || ! -x "$sparkle_bin/sign_update" || ! -x "$sparkle_bin/generate_keys" ]]; then
  echo "AERIVOICE_SPARKLE_BIN must point to the pinned Sparkle 2.10.0 bin directory." >&2
  exit 64
fi
if [[ ! -s "$release_notes" || "$release_notes" != *.txt ]]; then
  echo "AERIVOICE_RELEASE_NOTES must point to nonempty plain-text .txt notes." >&2
  exit 64
fi
history_args=()
if [[ -n "$previous_appcast" && "$initial_feed" == 0 && -f "$previous_appcast" ]]; then
  history_args=(--previous "$previous_appcast")
  "$sparkle_bin/sign_update" --account "$sparkle_account" --verify "$previous_appcast"
elif [[ -z "$previous_appcast" && "$initial_feed" == 1 ]]; then
  history_args=(--initial-feed)
else
  echo "Set AERIVOICE_PREVIOUS_APPCAST, or AERIVOICE_INITIAL_FEED=1 for the first-ever feed only." >&2
  exit 64
fi
# Only the public half is exported; signing tools keep the private key in Keychain.
update_public_key="$("$sparkle_bin/generate_keys" --account "$sparkle_account" -p)"
if [[ -z "$update_public_key" ]]; then
  echo "No Sparkle public key found for the configured Keychain account." >&2
  exit 1
fi

marketing_version="${release_version%%-*}"
tag="v$release_version"
commit="$(git rev-parse HEAD)"
if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
  tag_commit="$(git rev-list -n 1 "$tag")"
  if [[ "$tag_commit" != "$commit" ]]; then
    echo "$tag points to $tag_commit, not the current commit $commit." >&2
    exit 1
  fi
fi

artifact_dir="$repository_root/dist/$tag"
if [[ -e "$artifact_dir" ]]; then
  echo "$artifact_dir already exists; move it aside before rebuilding." >&2
  exit 1
fi

release_tmp="$(mktemp -d "${TMPDIR:-/tmp}/aerivoice-release.XXXXXX")"
cleanup() {
  rm -rf "$release_tmp"
}
trap cleanup EXIT

archive_path="$release_tmp/AeriVoice.xcarchive"
export_path="$release_tmp/export"
app_path="$export_path/AeriVoice.app"
app_zip="$release_tmp/AeriVoice.zip"
release_output="$release_tmp/output"
dmg_name="AeriVoice-$tag-arm64.dmg"
dmg_path="$release_output/$dmg_name"
dsym_name="AeriVoice-$tag.dSYM.zip"
mkdir -p "$release_output"

echo "Building $tag ($marketing_version build $build_number) from $commit"
xcodebuild \
  -project AeriVoice.xcodeproj \
  -scheme AeriVoice \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$archive_path" \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=NO \
  MARKETING_VERSION="$marketing_version" \
  CURRENT_PROJECT_VERSION="$build_number" \
  AERIVOICE_SOURCE_REVISION="$commit" \
  AERIVOICE_RELEASE_VERSION="$release_version" \
  AERIVOICE_UPDATE_PUBLIC_KEY="$update_public_key" \
  DEVELOPMENT_TEAM="$development_team" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$signing_identity" \
  SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) AERIVOICE_DISTRIBUTION' \
  OTHER_CODE_SIGN_FLAGS="--timestamp" \
  archive

# Export re-signs nested Sparkle services with the application's Developer ID.
export_options="$release_tmp/ExportOptions.plist"
python3 - "$export_options" "$development_team" "$signing_identity" <<'PYEXPORT'
import plistlib
import sys
with open(sys.argv[1], 'wb') as output:
    plistlib.dump({'method': 'developer-id', 'signingStyle': 'manual',
                  'teamID': sys.argv[2], 'signingCertificate': sys.argv[3],
                  'stripSwiftSymbols': False}, output)
PYEXPORT
xcodebuild -exportArchive -archivePath "$archive_path" \
  -exportPath "$export_path" -exportOptionsPlist "$export_options"

if [[ ! -d "$app_path" ]]; then
  echo "Export did not contain AeriVoice.app." >&2
  exit 1
fi

actual_archs="$(lipo -archs "$app_path/Contents/MacOS/AeriVoice")"
if [[ "$actual_archs" != "arm64" ]]; then
  echo "Expected an arm64-only executable; found: $actual_archs" >&2
  exit 1
fi

actual_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_path/Contents/Info.plist")"
actual_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app_path/Contents/Info.plist")"
if [[ "$actual_version" != "$marketing_version" || "$actual_build" != "$build_number" ]]; then
  echo "Unexpected bundle version: $actual_version ($actual_build)." >&2
  exit 1
fi

signature_details="$(codesign -dvvv "$app_path" 2>&1)"
if ! grep -Fqx "Authority=$signing_identity" <<< "$signature_details"; then
  echo "The exported app is not signed by the requested Developer ID identity." >&2
  exit 1
fi
if ! grep -Fqx "TeamIdentifier=$development_team" <<< "$signature_details"; then
  echo "The exported app does not use the requested development team." >&2
  exit 1
fi
if ! grep -Eq '^CodeDirectory .*flags=.*\(runtime\)' <<< "$signature_details"; then
  echo "The exported app does not have the hardened-runtime signature flag." >&2
  exit 1
fi

entitlements_path="$release_tmp/AeriVoice.entitlements.plist"
codesign -d --entitlements "$entitlements_path" --xml "$app_path" 2>/dev/null
if [[ "$(plutil -extract 'com\.apple\.security\.device\.audio-input' raw "$entitlements_path" 2>/dev/null || true)" != "true" ]]; then
  echo "The exported app is missing its audio-input entitlement." >&2
  exit 1
fi
if [[ "$(plutil -extract 'com\.apple\.security\.get-task-allow' raw "$entitlements_path" 2>/dev/null || true)" == "true" ]]; then
  echo "The exported app unexpectedly allows debugger attachment." >&2
  exit 1
fi

codesign --verify --deep --strict --verbose=2 "$app_path"
ditto -c -k --keepParent "$app_path" "$app_zip"
xcrun notarytool submit "$app_zip" --keychain-profile "$notary_profile" --wait
xcrun stapler staple "$app_path"
xcrun stapler validate "$app_path"
spctl --assess --type execute --verbose=4 "$app_path"

"$dmg_python" "$script_dir/build-dmg.py" build \
  --app "$app_path" --volume-name AeriVoice --output "$dmg_path"
codesign --force --timestamp --sign "$signing_identity" "$dmg_path"
xcrun notarytool submit "$dmg_path" --keychain-profile "$notary_profile" --wait
xcrun stapler staple "$dmg_path"
xcrun stapler validate "$dmg_path"
codesign --verify --verbose=2 "$dmg_path"
spctl --assess --type open --context context:primary-signature --verbose=4 "$dmg_path"

python3 "$script_dir/generate-update-feed.py" \
  --dmg "$dmg_path" --app "$app_path" --notes "$release_notes" \
  --version "$release_version" --build "$build_number" \
  --sparkle-bin "$sparkle_bin" --account "$sparkle_account" \
  --output "$release_output/appcast.xml" "${history_args[@]}"

if [[ ! -d "$archive_path/dSYMs/AeriVoice.app.dSYM" ]]; then
  echo "Archive did not contain AeriVoice.app.dSYM." >&2
  exit 1
fi
ditto -c -k --keepParent "$archive_path/dSYMs/AeriVoice.app.dSYM" "$release_output/$dsym_name"

(
  cd "$release_output"
  shasum -a 256 "$dmg_name" > "$dmg_name.sha256"
  shasum -a 256 -c "$dmg_name.sha256"
)

{
  printf 'tag=%s\n' "$tag"
  printf 'commit=%s\n' "$commit"
  printf 'marketing_version=%s\n' "$marketing_version"
  printf 'build_number=%s\n' "$build_number"
  printf 'architecture=arm64\n'
  printf 'executable_uuid=%s\n' "$(dwarfdump --uuid "$app_path/Contents/MacOS/AeriVoice")"
  printf 'symbols_uuid=%s\n' "$(dwarfdump --uuid "$archive_path/dSYMs/AeriVoice.app.dSYM")"
  printf 'xcode=%s\n' "$(xcodebuild -version | tr '\n' ' ')"
} > "$release_output/release-info.txt"

mkdir -p "$(dirname "$artifact_dir")"
mv "$release_output" "$artifact_dir"

echo "Verified release artifacts:"
find "$artifact_dir" -maxdepth 1 -type f -print

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
app_path="$archive_path/Products/Applications/AeriVoice.app"
app_zip="$release_tmp/AeriVoice.zip"
dmg_stage="$release_tmp/dmg"
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
  DEVELOPMENT_TEAM="$development_team" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$signing_identity" \
  SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) AERIVOICE_DISTRIBUTION' \
  OTHER_CODE_SIGN_FLAGS="--timestamp" \
  archive

if [[ ! -d "$app_path" ]]; then
  echo "Archive did not contain AeriVoice.app." >&2
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
  echo "The archived app is not signed by the requested Developer ID identity." >&2
  exit 1
fi
if ! grep -Fqx "TeamIdentifier=$development_team" <<< "$signature_details"; then
  echo "The archived app does not use the requested development team." >&2
  exit 1
fi
if ! grep -Eq '^CodeDirectory .*flags=.*\(runtime\)' <<< "$signature_details"; then
  echo "The archived app does not have the hardened-runtime signature flag." >&2
  exit 1
fi

entitlements_path="$release_tmp/AeriVoice.entitlements.plist"
codesign -d --entitlements "$entitlements_path" --xml "$app_path" 2>/dev/null
if [[ "$(plutil -extract 'com\.apple\.security\.device\.audio-input' raw "$entitlements_path" 2>/dev/null || true)" != "true" ]]; then
  echo "The archived app is missing its audio-input entitlement." >&2
  exit 1
fi
if [[ "$(plutil -extract 'com\.apple\.security\.get-task-allow' raw "$entitlements_path" 2>/dev/null || true)" == "true" ]]; then
  echo "The archived app unexpectedly allows debugger attachment." >&2
  exit 1
fi

codesign --verify --deep --strict --verbose=2 "$app_path"
ditto -c -k --keepParent "$app_path" "$app_zip"
xcrun notarytool submit "$app_zip" --keychain-profile "$notary_profile" --wait
xcrun stapler staple "$app_path"
xcrun stapler validate "$app_path"
spctl --assess --type execute --verbose=4 "$app_path"

mkdir -p "$dmg_stage"
ditto "$app_path" "$dmg_stage/AeriVoice.app"
ln -s /Applications "$dmg_stage/Applications"
hdiutil create \
  -volname AeriVoice \
  -srcfolder "$dmg_stage" \
  -format UDZO \
  -ov \
  "$dmg_path"
codesign --force --timestamp --sign "$signing_identity" "$dmg_path"
xcrun notarytool submit "$dmg_path" --keychain-profile "$notary_profile" --wait
xcrun stapler staple "$dmg_path"
xcrun stapler validate "$dmg_path"
codesign --verify --verbose=2 "$dmg_path"
spctl --assess --type open --context context:primary-signature --verbose=4 "$dmg_path"

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
  printf 'xcode=%s\n' "$(xcodebuild -version | tr '\n' ' ')"
} > "$release_output/release-info.txt"

mkdir -p "$(dirname "$artifact_dir")"
mv "$release_output" "$artifact_dir"

echo "Verified release artifacts:"
find "$artifact_dir" -maxdepth 1 -type f -print

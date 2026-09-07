#!/bin/bash

set -euo pipefail
umask 077

sample_count="${1:-10}"
idle_seconds="${2:-1}"
output_path="${3:-/tmp/aerivoice-synthetic-pipeline-$(date +%Y%m%d-%H%M%S).jsonl}"
voice_name="${4:-Samantha}"
warming_mode="${5:-on}"
configuration_path="/tmp/aerivoice-synthetic-pipeline-benchmark.plist"
derived_data_path="/tmp/aerivoice-synthetic-pipeline-derived-data"
temporary_directory="$(/usr/bin/mktemp -d /tmp/aerivoice-synthetic-pipeline.XXXXXX)"
audio_path="$temporary_directory/fixture.aiff"
credential_pipe_path="$temporary_directory/credentials.pipe"
credential_writer_pid=""

cleanup() {
  if [[ -n "$credential_writer_pid" ]] \
    && /bin/kill -0 "$credential_writer_pid" 2>/dev/null
  then
    /bin/kill "$credential_writer_pid" 2>/dev/null || true
    wait "$credential_writer_pid" 2>/dev/null || true
  fi
  unset soniox_api_key cerebras_api_key
  /bin/rm -f "$configuration_path"
  if [[ "$temporary_directory" == /tmp/aerivoice-synthetic-pipeline.* ]]; then
    /bin/rm -rf "$temporary_directory"
  fi
}
trap cleanup EXIT

if [[ ! "$sample_count" =~ ^[1-9][0-9]*$ ]]; then
  echo "Sample count must be a positive integer." >&2
  exit 64
fi
if [[ ! "$idle_seconds" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  echo "Idle seconds must be a non-negative number." >&2
  exit 64
fi
case "$warming_mode" in
  on) total_samples="$sample_count" ;;
  compare) total_samples=$((sample_count * 2)) ;;
  *) echo "Warming mode must be on or compare." >&2; exit 64 ;;
esac
if ! /usr/bin/say -v '?' | /usr/bin/awk -v voice="$voice_name" \
  '$1 == voice { found = 1 } END { exit !found }'
then
  echo "The requested macOS voice is unavailable: $voice_name" >&2
  exit 1
fi
read_credential() {
  local account="$1"
  /usr/bin/perl -e 'alarm shift; exec @ARGV or die "Could not launch security: $!\n"' \
    60 /usr/bin/security find-generic-password \
    -s com.danielou.AeriVoice.credentials.v2 -a "$account" -w 2>/dev/null
}

echo "Reading the stored Soniox credential; choose Allow if macOS asks."
if ! soniox_api_key="$(read_credential soniox)" || [[ -z "$soniox_api_key" ]]; then
  echo "The installed AeriVoice Soniox credential could not be read from Keychain." >&2
  exit 1
fi
echo "Reading the stored Cerebras credential; choose Allow if macOS asks."
if ! cerebras_api_key="$(read_credential cerebras)" || [[ -z "$cerebras_api_key" ]]; then
  echo "The installed AeriVoice Cerebras credential could not be read from Keychain." >&2
  exit 1
fi

/bin/rm -f "$configuration_path"

/usr/bin/say \
  -v "$voice_name" \
  -r 190 \
  -o "$audio_path" \
  --data-format=BEI16@16000 \
  '[[slnc 200]] AeriVoice synthetic benchmark number forty two. Please send the draft on Friday morning. [[slnc 200]]'

/usr/bin/plutil -create xml1 "$configuration_path"
/usr/bin/plutil -insert sampleCount -integer "$sample_count" "$configuration_path"
/usr/bin/plutil -insert idleSeconds -float "$idle_seconds" "$configuration_path"
/usr/bin/plutil -insert audioPath -string "$audio_path" "$configuration_path"
/usr/bin/plutil -insert outputPath -string "$output_path" "$configuration_path"
/usr/bin/plutil -insert credentialPipePath -string "$credential_pipe_path" "$configuration_path"
if [[ "$warming_mode" == compare ]]; then
  /usr/bin/plutil -insert compareWarming -bool true "$configuration_path"
fi
/bin/chmod 600 "$configuration_path"

/usr/bin/mkfifo "$credential_pipe_path"
/bin/chmod 600 "$credential_pipe_path"
(
  builtin printf '%s\0%s\0' "$soniox_api_key" "$cerebras_api_key" > "$credential_pipe_path"
) &
credential_writer_pid="$!"
unset soniox_api_key cerebras_api_key

runner_timeout_seconds="$(/usr/bin/awk \
  -v samples="$total_samples" -v idle="$idle_seconds" \
  'BEGIN { printf "%.0f", 60 + samples * (20 + idle) }')"

/usr/bin/perl -e 'alarm shift; exec @ARGV or die "Could not launch xcodebuild: $!\n"' \
  "$runner_timeout_seconds" \
  /usr/bin/xcodebuild \
  -project AeriVoice.xcodeproj \
  -scheme AeriVoice \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$derived_data_path" \
  -only-testing:AeriVoiceTests/SyntheticPipelineLiveBenchmarkTests/testSyntheticSonioxCerebrasPipeline \
  test

xcrun swift scripts/summarize-synthetic-pipeline.swift "$output_path"

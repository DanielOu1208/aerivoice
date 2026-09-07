#!/bin/bash

set -euo pipefail
umask 077

sample_count="${1:-30}"
idle_seconds="${2:-90}"
output_path="${3:-/tmp/aerivoice-cerebras-baseline-$(date +%Y%m%d-%H%M%S).jsonl}"
configuration_path="/tmp/aerivoice-cerebras-live-benchmark.plist"
derived_data_path="/tmp/aerivoice-cerebras-live-derived-data"

if [[ ! "$sample_count" =~ ^[1-9][0-9]*$ ]]; then
  echo "Sample count must be a positive integer." >&2
  exit 64
fi
if [[ ! "$idle_seconds" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  echo "Idle seconds must be a non-negative number." >&2
  exit 64
fi
if ! security find-generic-password \
  -s com.danielou.AeriVoice.credentials.v2 -a cerebras >/dev/null 2>&1
then
  echo "No Cerebras credential is available in the installed AeriVoice Keychain namespace." >&2
  exit 1
fi

cleanup() {
  /bin/rm -f "$configuration_path"
}
trap cleanup EXIT
cleanup

/usr/bin/plutil -create xml1 "$configuration_path"
/usr/bin/plutil -insert sampleCount -integer "$sample_count" "$configuration_path"
/usr/bin/plutil -insert idleSeconds -float "$idle_seconds" "$configuration_path"
/usr/bin/plutil -insert outputPath -string "$output_path" "$configuration_path"
/bin/chmod 600 "$configuration_path"

xcodebuild \
  -project AeriVoice.xcodeproj \
  -scheme AeriVoice \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$derived_data_path" \
  -only-testing:AeriVoiceTests/CerebrasCleanupLiveBenchmarkTests/testColdCleanupBaseline \
  test

xcrun swift scripts/summarize-latency.swift "$output_path"

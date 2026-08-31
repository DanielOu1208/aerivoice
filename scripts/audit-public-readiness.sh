#!/bin/bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_root="$(cd "$script_dir/.." && pwd)"
cd "$repository_root"

if [[ -n "$(git status --porcelain)" ]]; then
  echo "Public-readiness audits require a clean working tree." >&2
  exit 1
fi

required_files=(
  README.md
  LICENSE
  PRIVACY.md
  SECURITY.md
  CONTRIBUTING.md
  .github/workflows/ci.yml
  docs/images/aerivoice-icon.png
  docs/images/social-preview.png
)
for required_file in "${required_files[@]}"; do
  if [[ ! -f "$required_file" ]]; then
    echo "Missing public-facing file: $required_file" >&2
    exit 1
  fi
done

if git grep -n 'DEVELOPMENT_TEAM = ' -- '*.pbxproj'; then
  echo "A personal development team remains in tracked project configuration." >&2
  exit 1
fi

for forbidden_path in \
  AeriVoice/Sounds/dictation-start.wav \
  AeriVoice/Sounds/dictation-stop.wav \
  AeriVoice/Sounds/dictation-error.wav
do
  if git rev-list --objects --all | grep -Fq " $forbidden_path"; then
    echo "$forbidden_path remains in Git history." >&2
    exit 1
  fi
done

tracked_private_files="$({
  git ls-files \
    | grep -E '(^|/)(\.env($|\.)|dist/|[^/]+\.(p8|pem|p12|pfx|der|key|cer|csr|mobileprovision|provisionprofile|dmg|pkg)(/|$)|[^/]+\.(app|xcarchive|xcresult|dSYM)(/|$))' \
    | grep -Ev '(^|/)\.env\.example$'
} || true)"
if [[ -n "$tracked_private_files" ]]; then
  echo "A release credential or generated artifact is tracked." >&2
  printf '%s\n' "$tracked_private_files" >&2
  exit 1
fi

if ! command -v gitleaks >/dev/null 2>&1; then
  echo "gitleaks is required for the full-history audit." >&2
  exit 1
fi
gitleaks git --redact --no-banner
gitleaks dir . --redact --no-banner

echo "Public-readiness audit passed."

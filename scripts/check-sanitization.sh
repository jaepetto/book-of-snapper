#!/usr/bin/env bash
# Fails (non-zero exit) if tracked/staged Markdown contains org-identifying
# strings. Run before every commit — wired as .git/hooks/pre-commit and as
# `mise run check`.
set -euo pipefail

denylist=(
  'epfl'          # organization name
  'xaas\.'        # org-internal VM domain suffix
  'icvm'          # org-internal hostname prefix
  'netbox'        # org's specific IPAM product instance
  'uyuni'         # org's specific patch-management product instance
  'icit-'         # org-internal system prefix
  '\b10\.95\.'    # org-internal IP range
)

user_email="$(git config user.email 2>/dev/null || true)"
if [ -n "$user_email" ]; then
  denylist+=("$(printf '%s' "$user_email" | sed 's/[.[\*^$]/\\&/g')")
fi

files=$(git diff --cached --name-only --diff-filter=ACM -- '*.md' 2>/dev/null || true)
if [ -z "$files" ]; then
  files=$(git ls-files -- '*.md' 2>/dev/null || true)
fi
[ -z "$files" ] && exit 0

hit=0
for pattern in "${denylist[@]}"; do
  if out=$(grep -inE "$pattern" $files 2>/dev/null); then
    echo "$out"
    hit=1
  fi
done

if [ "$hit" -eq 1 ]; then
  echo "check-sanitization: org-identifying string found above — scrub before committing." >&2
  exit 1
fi
exit 0

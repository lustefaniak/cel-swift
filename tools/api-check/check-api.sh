#!/bin/bash
# Diagnoses API-breaking changes of the library products against a baseline, by default the
# latest release tag (CLAUDE.md "Source compatibility"). Prints a notice and exits 0 when the
# repository has no tag yet.
#
#   tools/build-guard/swiftlock tools/api-check/check-api.sh          # against the latest tag
#   tools/build-guard/swiftlock tools/api-check/check-api.sh 0.1.0    # against a given treeish
#
# Breakages that are intended (a minor bump before 1.0, a major one after) go in
# tools/api-check/allowlist.txt, one exact message per line, and are cleared once the next release is tagged.
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"

baseline="${1:-$(git describe --tags --abbrev=0 2>/dev/null || true)}"
if [ -z "$baseline" ]; then
  echo "no release tag yet: nothing to compare the API against"
  exit 0
fi

products=(CEL CELExtensions CELPolicy CELTest CELProtobuf)
args=(--products "${products[@]}")
allowlist="tools/api-check/allowlist.txt"
if [ -s "$allowlist" ]; then
  args+=(--breakage-allowlist-path "$allowlist")
fi
echo "comparing ${products[*]} against $baseline"
swift package --jobs "${JOBS:-4}" diagnose-api-breaking-changes "$baseline" "${args[@]}"

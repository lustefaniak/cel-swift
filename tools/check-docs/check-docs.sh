#!/bin/bash
# Documentation checks for the release: every library product has a DocC catalog, every public
# declaration has a doc comment (check_docs.py), and each DocC catalog under Sources builds without
# warnings (broken or ambiguous symbol links) when `docc` is available (Xcode, or a Swift toolchain
# that ships it).
#
#   tools/build-guard/swiftlock tools/check-docs/check-docs.sh     # locally (it builds)
#   tools/check-docs/check-docs.sh                                 # CI
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"

# Every target of a library product has a DocC catalog, Sources/<Target>/<Target>.docc.
missing_catalogs="$(swift package dump-package | python3 -c '
import json, os, sys
package = json.load(sys.stdin)
for product in package["products"]:
    if "library" not in product["type"]:
        continue
    for target in product["targets"]:
        if not os.path.isdir(f"Sources/{target}/{target}.docc"):
            print(f"Sources/{target}/{target}.docc")
')"
if [ -n "$missing_catalogs" ]; then
  echo "library products without a DocC catalog:" >&2
  echo "$missing_catalogs" >&2
  exit 1
fi

swift package --jobs "${JOBS:-4}" dump-symbol-graph --skip-synthesized-members --skip-inherited-docs \
  --emit-extension-block-symbols >/dev/null
graphs="$(ls -d .build/*/symbolgraph | head -1)"
python3 tools/check-docs/check_docs.py "$graphs"

docc="$(command -v docc || xcrun --find docc 2>/dev/null || true)"
if [ -z "$docc" ]; then
  echo "docc not found: skipping the catalog builds" >&2
  exit 0
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
status=0
for catalog in Sources/*/*.docc; do
  module="$(basename "$(dirname "$catalog")")"
  mkdir -p "$tmp/$module/graphs"
  cp "$graphs/$module".symbols.json "$tmp/$module/graphs/"
  cp "$graphs/$module"@*.symbols.json "$tmp/$module/graphs/" 2>/dev/null || true
  if "$docc" convert "$catalog" --fallback-display-name "$module" --fallback-bundle-identifier "$module" \
    --additional-symbol-graph-dir "$tmp/$module/graphs" --output-path "$tmp/$module/out.doccarchive" \
    --analyze --warnings-as-errors >"$tmp/$module/log" 2>&1; then
    echo "ok   $catalog"
  else
    echo "FAIL $catalog"
    grep -E "warning|error" "$tmp/$module/log" || cat "$tmp/$module/log"
    status=1
  fi
done
exit $status

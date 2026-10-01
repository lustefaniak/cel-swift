#!/bin/bash
# Regenerates the go-yaml / cel-go golden dumps compared by DifferentialTests.swift.
# Needs Go and the third_party/cel-go submodule.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../../../.." && pwd)"
bin="$(mktemp -d)/generate"
(cd "$here" && go build -o "$bin" .)
cd "$root"
files=()
while IFS= read -r f; do files+=("$f"); done < <(
  {
    find third_party/cel-go/policy/testdata third_party/cel-go/tools/celtest/testdata third_party/cel-go/common/env/testdata \
      -name '*.yaml' -o -name '*.celpolicy' -o -name '*.json'
    find Tests/CELPolicyTests/Goldens/cases -name '*.yaml'
  } | LC_ALL=C sort
)
"$bin" yaml "${files[@]}" > Tests/CELPolicyTests/Goldens/yaml_nodes.txt
"$bin" policy "${files[@]}" > Tests/CELPolicyTests/Goldens/policies.txt
rm -rf "$(dirname "$bin")"

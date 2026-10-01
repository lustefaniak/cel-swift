#!/bin/bash
# Runs every cel-go celtest suite (policy/testdata/*/tests.yaml and tools/celtest/testdata) with
# cel-go's celtest (this directory's TestCEL) and with `cel-swift policy test`, and fails when the
# two disagree on which tests pass.
#
#   tools/build-guard/swiftlock swift build -j 4 --product cel-swift
#   tools/celtest-go/compare.sh            # GOPROXY=off works once the module cache is warm
#
# A suite argument (e.g. `tools/celtest-go/compare.sh k8s`) limits the run to matching suites.
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
celgo="$root/third_party/cel-go"
swift_bin="${CEL_SWIFT_BIN:-$root/.build/debug/cel-swift}"
filter="${1:-}"
[ -x "$swift_bin" ] || { echo "missing $swift_bin: build the cel-swift product first" >&2; exit 2; }

# name;expression;tests;base config;config;extra flags
suites=(
  "k8s;policy/testdata/k8s/policy.yaml;policy/testdata/k8s/tests.yaml;;policy/testdata/k8s/config.yaml;k8s"
  "restricted_destinations_base_config;policy/testdata/restricted_destinations/policy.yaml;policy/testdata/restricted_destinations/tests.yaml;policy/testdata/restricted_destinations/base_config.yaml;policy/testdata/restricted_destinations/partial_config.yaml;"
  "raw_expr_file;tools/celtest/testdata/raw_expr.cel;tools/celtest/testdata/raw_expr_tests.yaml;;tools/celtest/testdata/config.yaml;"
  "raw_expr;a || i + fn(j) == 42;tools/celtest/testdata/raw_expr_tests.yaml;;tools/celtest/testdata/config.yaml;"
)
for dir in "$celgo"/policy/testdata/*/; do
  name="$(basename "$dir")"
  [ -f "$dir/tests.yaml" ] || continue
  [ "$name" = k8s ] && continue
  suites+=("$name;policy/testdata/$name/policy.yaml;policy/testdata/$name/tests.yaml;;policy/testdata/$name/config.yaml;")
done

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
status=0
for entry in "${suites[@]}"; do
  IFS=';' read -r name expr tests base config extra <<<"$entry"
  if [ -n "$filter" ] && [[ "$name" != *"$filter"* ]]; then
    continue
  fi
  abs() { case "$1" in *.yaml | *.cel | *.celpolicy) echo "$celgo/$1" ;; *) echo "$1" ;; esac; }
  go_args=(--cel_expr="$(abs "$expr")" --test_suite_path="$celgo/$tests" --config_path="$celgo/$config" --cel_go_test_fixtures)
  swift_args=(policy test --cel-expr "$(abs "$expr")" --test-suite "$celgo/$tests" --config "$celgo/$config" --cel-go-test-fixtures --verbose)
  if [ -n "$base" ]; then
    go_args+=(--base_config_path="$celgo/$base")
    swift_args+=(--base-config "$celgo/$base")
  fi
  if [ "$extra" = k8s ]; then
    go_args+=(--k8s_tags)
    swift_args+=(--k8s-tags)
  fi
  (cd "$root/tools/celtest-go" && go test -count=1 -run '^TestCEL$' -v . -args "${go_args[@]}" >"$tmp/go.out" 2>&1 || true)
  sed -En 's/^ *--- (PASS|FAIL): TestCEL\/([^ ]*) .*/\1 \2/p' "$tmp/go.out" | sort >"$tmp/go"
  # go test names subtests with spaces replaced by underscores.
  ("$swift_bin" "${swift_args[@]}" || true) \
    | sed -En 's/^--- (PASS|FAIL): (.*)$/\1 \2/p' | tr ' ' '_' | sed -E 's/^(PASS|FAIL)_/\1 /' | sort >"$tmp/swift"
  if [ ! -s "$tmp/go" ]; then
    echo "FAIL $name: cel-go ran no tests"
    tail -20 "$tmp/go.out"
    status=1
  elif diff -u "$tmp/go" "$tmp/swift" >"$tmp/diff"; then
    echo "ok   $name ($(wc -l <"$tmp/go" | tr -d ' ') tests, $(grep -c '^PASS' "$tmp/go" || true) passing)"
  else
    echo "FAIL $name: cel-go (-) and cel-swift (+) disagree"
    cat "$tmp/diff"
    status=1
  fi
done
exit $status

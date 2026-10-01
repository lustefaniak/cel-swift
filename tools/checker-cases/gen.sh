#!/bin/sh
# Regenerates Tests/CELTests/Fixtures/CheckerCases.swift from cel-go's checker/checker_test.go table.
# Run from the repository root. The dumper is copied into the cel-go submodule for the run and removed after.
set -eu
root=$(pwd)
dst="$root/third_party/cel-go/checker/zz_dump_cases_test.go"
cp "$root/tools/checker-cases/dump_cases_test.go" "$dst"
trap 'rm -f "$dst"' EXIT
(cd "$root/third_party/cel-go" && CHECKER_CASES_OUT="$root/Tests/CELTests/Fixtures/CheckerCases.swift" \
  go test ./checker -run TestDumpCheckerCasesAsSwift -count=1 >/dev/null)

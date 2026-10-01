#!/usr/bin/env bash
# Runs every fuzzer in parallel for the given time (or `replay`), logs in $FUZZ_WORK/<target>.log.
# Exits non-zero if any fuzzer found a crash, timeout or OOM.
#
#   Fuzz/run-all.sh <seconds|replay> [libFuzzer flags...]
set -uo pipefail
cd "$(dirname "$0")/.."
work="${FUZZ_WORK:-.build-fuzz-work}"
mkdir -p "$work"
pids=()
for target in parser checker evaluator; do
  Fuzz/run.sh "$target" "$@" > "$work/$target.log" 2>&1 &
  pids+=($!)
done
status=0
for i in "${!pids[@]}"; do
  if ! wait "${pids[$i]}"; then
    status=1
  fi
done
for target in parser checker evaluator; do
  echo "== $target"
  grep -E "^(stat::|#[0-9]+ +DONE|==[0-9]+==|SUMMARY|Done [0-9]+ runs|artifact_prefix|Test unit written)" "$work/$target.log" || true
  tail -3 "$work/$target.log"
done
exit $status

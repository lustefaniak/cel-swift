#!/usr/bin/env bash
# Runs one fuzzer built by Fuzz/build.sh (Linux only).
#
#   Fuzz/run.sh <parser|checker|evaluator> <seconds> [libFuzzer flags...]
#   Fuzz/run.sh <parser|checker|evaluator> replay       # run the checked-in corpus and regressions once
#
# The checked-in seed corpus is read-only input; new coverage goes to $FUZZ_WORK/corpus-<target>
# (default .build-fuzz-work). Crashes, timeouts and OOMs land in $FUZZ_WORK/artifacts/<target>/.
set -euo pipefail
cd "$(dirname "$0")/.."
target="$1"
duration="$2"
shift 2
scratch="${FUZZ_SCRATCH:-.build-fuzz}"
work="${FUZZ_WORK:-.build-fuzz-work}"
binary="$scratch/release/cel-fuzz-$target"
seeds="Fuzz/corpus/$target"
regressions="Fuzz/regressions/$target"
mkdir -p "$regressions"
# LeakSanitizer reports the one-time lazy initialisation of Swift globals (a constant ~14 KB that does
# not grow with the number of runs), so leak detection is off; a per-input leak (a retain cycle in
# evaluation state) still shows up as RSS growth past -rss_limit_mb.
export ASAN_OPTIONS="${ASAN_OPTIONS:-detect_leaks=0}"
common=(-dict=Fuzz/cel.dict -max_len=4096 -timeout=10 -rss_limit_mb=2048 -malloc_limit_mb=2048 -detect_leaks=0)

if [ "$duration" = replay ]; then
  # A directory of inputs is executed once each; any crash, timeout or OOM fails the run.
  mkdir -p "$work/artifacts/$target"
  exec "$binary" "${common[@]}" -runs=0 -artifact_prefix="$work/artifacts/$target/" "$@" "$seeds" "$regressions"
fi

mkdir -p "$work/corpus-$target" "$work/artifacts/$target"
exec "$binary" "${common[@]}" -max_total_time="$duration" -print_final_stats=1 \
  -artifact_prefix="$work/artifacts/$target/" "$@" "$work/corpus-$target" "$seeds" "$regressions"

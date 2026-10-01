#!/usr/bin/env bash
# Builds the libFuzzer targets (Linux only). Run inside a Swift toolchain image, e.g.
#   docker run --rm -v "$PWD":/w -v cel-fuzz-build:/build -w /w -e FUZZ_SCRATCH=/build swift:6.0-noble Fuzz/build.sh
# (Docker Desktop bind mounts break SwiftPM's build database, hence the volume for the scratch path.)
# Binaries land in $FUZZ_SCRATCH/release/cel-fuzz-{parser,checker,eval}; FUZZ_SCRATCH defaults to .build-fuzz.
set -euo pipefail
cd "$(dirname "$0")/.."
export CEL_FUZZ=1
scratch="${FUZZ_SCRATCH:-.build-fuzz}"
for target in cel-fuzz-parser cel-fuzz-checker cel-fuzz-eval; do
  swift build -c release --scratch-path "$scratch" --product "$target" \
    -Xswiftc -sanitize=fuzzer,address -Xswiftc -g
done

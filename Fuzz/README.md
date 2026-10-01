# Fuzzing

libFuzzer targets for the untrusted-input paths. Linux only (`-sanitize=fuzzer`), so on macOS run them
in the Swift docker image.

| Target | Exercises |
|---|---|
| `cel-fuzz-parser` | lexer, parser, macros, debug printer, unparser and reparse, with the default and `parser_test.go` limits |
| `cel-fuzz-checker` | parse + type-check against the fuzz environment, checked-AST printer |
| `cel-fuzz-evaluator` | parse, check (else parse-only), static cost estimate, plan and evaluate, plain and exhaustive + optimized, with a cost limit and a 2 s interrupt deadline |

The fuzz environment (`Sources/CELFuzzSupport`) has the standard library, optional types, the conformance
`TestAllTypes` messages (container `cel.expr.conformance.proto3`) and variables `i u d s b l m x o t dur`
of different types with fixed bindings.

The targets exist only when `CEL_FUZZ=1` is set while SwiftPM reads `Package.swift`, so the normal build and
CI are unaffected. SwiftPM links an executable's `main` to `<module>_main`, which keeps libFuzzer's own
`main` out of the link, so each target's entry point calls `LLVMFuzzerRunDriver` (`Sources/CELFuzzDriver`).

```sh
# Docker Desktop bind mounts break SwiftPM's build database: keep the scratch path in a volume.
docker run --rm --memory 8g -v "$PWD":/w -v cel-fuzz-build:/build -w /w \
  -e FUZZ_SCRATCH=/build -e FUZZ_WORK=/build/work swift:6.0-noble \
  bash -c 'Fuzz/build.sh && Fuzz/run-all.sh 600'
```

- `Fuzz/run.sh <parser|checker|evaluator> <seconds|replay> [libFuzzer flags]` runs one target;
  `Fuzz/run-all.sh <seconds|replay>` runs all three in parallel and fails if any finds something.
  `replay` executes the seed corpus and `Fuzz/regressions/<target>` once (what CI does first).
- Limits: `-max_len=4096 -timeout=10 -rss_limit_mb=2048 -malloc_limit_mb=2048`. Leak detection is off:
  LeakSanitizer reports the one-time initialisation of Swift globals (a constant amount, independent of
  the number of runs); a per-input leak shows up as RSS growth instead.
- New coverage goes to `$FUZZ_WORK/corpus-<target>`, findings to `$FUZZ_WORK/artifacts/<target>/`.
- Any crash, timeout or OOM is a bug. Add the input to `Fuzz/regressions/<target>/`, a reproducer test to
  `Tests/CELTests/FuzzRegressionTests.swift` (committed before the fix), then fix.
- `Fuzz/make-corpus.py` regenerates the seed corpora from the parser fixtures; `Fuzz/cel.dict` is the
  token dictionary.

CI runs the replay and 60 s per target on every push (`ci.yml`, job `fuzz`) and 30 min per target nightly
(`nightly.yml`), keeping the generated corpus in the actions cache.

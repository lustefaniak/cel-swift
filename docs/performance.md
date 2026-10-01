# Performance

cel-swift against cel-go on the same expressions, phase by phase. The plan's bar is "no pathological
slowness", not beating cel-go; this file tracks where the time goes and what the open decisions would buy.

## Running the benchmarks

`tools/bench/cases.json` holds the expressions, their variable types and their inputs. Inputs are CEL
expressions evaluated once with the lists extension (`lists.range(1000)`), so both drivers build the same
data the same way.

- `Benchmarks/CELBenchmarks` (Swift) and `tools/bench/go` (cel-go v0.32.0 from `third_party/cel-go`) time
  `parse`, `check`, `plan` (`env.program`) and `eval` (`program.evaluate` with prebuilt variables, cel-go
  `prg.Eval` with a prebuilt activation). Each phase is calibrated to rounds of about 100 ms, run `--rounds`
  times, and the fastest round is reported: the machine these numbers come from runs many parallel builds,
  and the fastest round is the one least disturbed by them.
- `tools/bench/bench.py` builds the Swift driver in release through `swiftlock`, runs both and prints the
  table. `--swift-only --save a.tsv`, then `--baseline a.tsv` after a change, gives before/after numbers for
  a commit; `--phase ev` (a prefix) and `--filter <case>` narrow the run. The Swift driver also takes
  `--threads n` (inverse throughput with n threads running the phase at once).
- Profiling: run `.build/release/CELBenchmarks --filter <case> --phase <phase> --rounds 1000` and attach
  `sample <pid> 6` (or Instruments' Time Profiler). The release binary keeps its symbols.

## Results

Apple M1 Max, macOS, Swift 6.3 toolchain, Go 1.26; 2026-10-01. `tools/bench/bench.py --swift-only --rounds 9`,
fastest of 9 rounds, under heavy background load (parallel agent builds), so differences under about 10% are
noise; the parse, check and plan differences between the two Swift columns are such noise (the change does
not touch those phases). The cel-go column is the best of 3 interleaved passes from the earlier measurement
on the same machine (`tools/bench/go`, cel-go v0.32.0): a fresh cel-go run during this one was disturbed by up
to 4× on some cells.

- **before**: `b01d58c`, main before the payload change.
- **after**: `indirect` list, map, object and error cases in `Value` (decision 6 in `docs/decisions.md`).
- **×go**: time relative to cel-go (lower is better, 1.00 = parity).

| case | phase | cel-go | before | ×go | after | ×go | after/before |
|---|---|---:|---:|---:|---:|---:|---:|
| arith | parse | 35.2 µs | 296.1 µs | 8.41 | 296.9 µs | 8.43 | 1.00 |
| arith | check | 19.4 µs | 38.1 µs | 1.96 | 37.4 µs | 1.93 | 0.98 |
| arith | plan | 2.1 µs | 6.2 µs | 2.95 | 6.1 µs | 2.93 | 0.99 |
| arith | eval | 266 ns | 1.1 µs | 4.07 | 638 ns | 2.40 | 0.59 |
| select-chain | parse | 64.9 µs | 518.3 µs | 7.99 | 523.6 µs | 8.07 | 1.01 |
| select-chain | check | 40.4 µs | 73.1 µs | 1.81 | 72.0 µs | 1.78 | 0.98 |
| select-chain | plan | 3.6 µs | 12.3 µs | 3.42 | 12.2 µs | 3.38 | 0.99 |
| select-chain | eval | 574 ns | 3.3 µs | 5.70 | 1.8 µs | 3.08 | 0.54 |
| literals | parse | 71.9 µs | 570.2 µs | 7.93 | 567.5 µs | 7.89 | 1.00 |
| literals | check | 24.7 µs | 47.9 µs | 1.94 | 46.5 µs | 1.88 | 0.97 |
| literals | plan | 2.3 µs | 6.6 µs | 2.89 | 6.7 µs | 2.90 | 1.01 |
| literals | eval | 923 ns | 3.7 µs | 4.03 | 3.0 µs | 3.30 | 0.82 |
| policy | parse | 173.8 µs | 1.01 ms | 5.80 | 977.1 µs | 5.62 | 0.97 |
| policy | check | 97.4 µs | 154.0 µs | 1.58 | 151.0 µs | 1.55 | 0.98 |
| policy | plan | 10.0 µs | 30.0 µs | 3.00 | 30.0 µs | 3.00 | 1.00 |
| policy | eval | 12.7 µs | 59.7 µs | 4.70 | 29.2 µs | 2.30 | 0.49 |
| comprehension-map-filter | parse | 59.7 µs | 523.1 µs | 8.76 | 510.3 µs | 8.55 | 0.98 |
| comprehension-map-filter | check | 74.8 µs | 103.7 µs | 1.39 | 101.6 µs | 1.36 | 0.98 |
| comprehension-map-filter | plan | 5.1 µs | 14.5 µs | 2.84 | 14.2 µs | 2.78 | 0.98 |
| comprehension-map-filter | eval | 549.6 µs | 1.41 ms | 2.56 | 902.7 µs | 1.64 | 0.64 |
| comprehension-nested | parse | 35.1 µs | 419.6 µs | 11.95 | 419.1 µs | 11.94 | 1.00 |
| comprehension-nested | check | 17.3 µs | 28.3 µs | 1.63 | 27.3 µs | 1.58 | 0.97 |
| comprehension-nested | plan | 3.0 µs | 9.0 µs | 3.01 | 8.8 µs | 2.94 | 0.98 |
| comprehension-nested | eval | 946.9 µs | 3.21 ms | 3.39 | 1.58 ms | 1.67 | 0.49 |
| string-ops | parse | 55.2 µs | 466.4 µs | 8.45 | 438.6 µs | 7.95 | 0.94 |
| string-ops | check | 52.6 µs | 91.5 µs | 1.74 | 78.6 µs | 1.49 | 0.86 |
| string-ops | plan | 4.0 µs | 17.2 µs | 4.29 | 12.3 µs | 3.09 | 0.72 |
| string-ops | eval | 10.5 µs | 53.0 µs | 5.05 | 21.6 µs | 2.06 | 0.41 |
| long-or | parse | 444.9 µs | 2.91 ms | 6.53 | 1.59 ms | 3.57 | 0.55 |
| long-or | check | 692.8 µs | 385.4 µs | 0.56 | 376.0 µs | 0.54 | 0.98 |
| long-or | plan | 23.7 µs | 67.5 µs | 2.85 | 64.9 µs | 2.74 | 0.96 |
| long-or | eval | 2.6 µs | 13.8 µs | 5.30 | 6.6 µs | 2.56 | 0.48 |

Earlier changes on main, measured back to back in their commit messages: policy eval 0.88×, string-ops eval
0.85× (UTF-8 buffers); parse 0.94× to 0.97× on small inputs, policy 0.87×, long-or 0.67× (token text).

## Where the time goes

- **Parse** (8× cel-go): about half is ANTLR adaptive prediction rebuilding the prediction DFAs that
  antlr4-go keeps in a process-wide static cache; with the cache warm (shared cache prototype) parsing is
  2–3× cel-go, the remainder being parse-tree and token allocation and release (ARC frees the per-parse
  tree eagerly, about a fifth of the profile) and the thread hop `LargeStack` makes for inputs with many
  operators.
- **Check** (1.3–2× cel-go, faster on `long-or`): no single hotspot.
- **Plan** (about 3× cel-go): node and attribute allocation, `Expr.depth`, and freeing the previous
  program; cel-go plans into a garbage-collected graph.
- **Eval** (1.6–3.3× cel-go): before the payload change, copying `Value` dominated: with 40-byte
  existential payloads `Value` was 41 bytes (stride 48), and every copy or destroy of any `Value`, even an
  `int`, went through the outlined value witness (`initializeWithCopy for Value`, `destroy for Value`),
  20–30% of every eval profile. With the boxed payloads `Value` is 17 bytes (stride 24). What remains is
  ARC traffic, dynamic exclusivity checks on the comprehension `Folder`'s stored properties, `as?` casts and
  runtime type guards.

## Decisions

### (a) Boxed list, map, object and error payloads in `Value`: landed

`.list`, `.map`, `.object` and `.error` are `indirect`: Swift stores those payloads in a heap box, `Value`
is 17 bytes (stride 24) with only references or trivial data in its payloads, and copying a list is one
retain instead of an existential buffer copy. Eval got 1.2–2.4× faster (table above: policy 59.7 → 29.2 µs,
comprehension-nested 3.21 → 1.58 ms, string-ops 53.0 → 21.6 µs), from 2.6–5.7× cel-go to 1.6–3.3×.
Constructing one of those values costs one more allocation.

The change is source compatible: the case list, `ListValue` / `MapValue` / `ObjectValue`, `ArrayList` and
`OrderedMap` are unchanged, so clients pattern match exactly as before. It is a layout change of a public
enum, invisible to source but part of the ABI (relevant only with library evolution, which this package
does not enable). Going further (final classes in place of the existentials, dropping `as? ArrayList`
casts) would change the public collection API and was rejected (`docs/decisions.md` § 6).

### (b) Shared ANTLR prediction cache (decided: implementing)

The prototype (`perf/shared-parser-cache`) moves the per-parse `decisionToDFA` into `PredictionCache.shared`,
an `@unchecked Sendable` final class guarded by a pthread mutex (`Synchronization.Mutex` needs macOS 15 /
iOS 18), and runs all of `adaptivePredict` under the lock. Single-threaded parse becomes 3–5× faster (policy
1.06 ms → 461 µs, comprehension-nested 422 → 87 µs), 2–3× cel-go. A test parses concurrently from 16 tasks
and compares with sequential parses.

Costs: global mutable state in `CEL`, a cache that grows with the variety of inputs (as in cel-go, never
trimmed), and the coarse lock serializes prediction: with 8 threads parsing `arith` at once (`--threads 8`)
the prototype managed one parse per 135 µs of wall time against 92 µs on a single thread, so concurrent
parsers ran slower together than one alone. The decision (`docs/decisions.md` § 9) is antlr4-go's finer
locking (`stateMu`, `edgeMu`, target states computed outside the lock), being implemented.

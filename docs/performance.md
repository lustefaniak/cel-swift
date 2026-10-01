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

Apple M1 Max, macOS, Swift 6.3 toolchain, Go 1.26; 2026-10-01. Best of 3 interleaved passes of 7 rounds,
under heavy background load (load average 75 to 240 on 10 cores), so differences under about 10% are noise;
a few single cells (`policy` parse on main, `comprehension-map-filter` eval in "both") are visibly
disturbed outliers.

- **before**: `70410af`, the harness commit, before any change.
- **main**: after the changes on main (UTF-8 buffer string operations, token text encoding).
- **shared cache**: branch `perf/shared-parser-cache` (decision below).
- **class payloads**: branch `perf/class-payloads` (decision below).
- **both**: the two prototypes merged.
- **×go**: time relative to cel-go (lower is better, 1.00 = parity).

| case | phase | cel-go | before | main | ×go | shared cache | class payloads | both | ×go |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|
| arith | parse | 35.2 µs | 309.1 µs | 294.1 µs | 8.36 | 92.1 µs | 293.4 µs | 92.6 µs | 2.63 |
| arith | check | 19.4 µs | 38.1 µs | 38.6 µs | 1.99 | 37.7 µs | 37.3 µs | 36.9 µs | 1.91 |
| arith | plan | 2.1 µs | 6.1 µs | 6.2 µs | 2.96 | 6.1 µs | 6.1 µs | 6.0 µs | 2.90 |
| arith | eval | 266 ns | 1.1 µs | 1.1 µs | 4.03 | 1.1 µs | 643 ns | 645 ns | 2.43 |
| select-chain | parse | 64.9 µs | 536.4 µs | 523.0 µs | 8.06 | 165.1 µs | 506.2 µs | 166.5 µs | 2.57 |
| select-chain | check | 40.4 µs | 72.3 µs | 71.6 µs | 1.77 | 71.2 µs | 70.8 µs | 70.8 µs | 1.75 |
| select-chain | plan | 3.6 µs | 12.0 µs | 12.1 µs | 3.31 | 12.1 µs | 11.8 µs | 12.0 µs | 3.30 |
| select-chain | eval | 574 ns | 2.9 µs | 3.2 µs | 5.51 | 3.2 µs | 1.7 µs | 1.8 µs | 3.15 |
| literals | parse | 71.9 µs | 580.0 µs | 559.1 µs | 7.77 | 196.0 µs | 553.0 µs | 196.1 µs | 2.73 |
| literals | check | 24.7 µs | 46.7 µs | 45.9 µs | 1.86 | 47.8 µs | 45.8 µs | 45.8 µs | 1.86 |
| literals | plan | 2.3 µs | 6.6 µs | 6.6 µs | 2.88 | 6.6 µs | 6.6 µs | 6.6 µs | 2.89 |
| literals | eval | 923 ns | 3.5 µs | 3.6 µs | 3.86 | 3.6 µs | 2.0 µs | 2.3 µs | 2.54 |
| policy | parse | 173.8 µs | 1.06 ms | 1.47 ms | 8.43 | 460.9 µs | 951.6 µs | 846.1 µs | 4.87 |
| policy | check | 97.4 µs | 150.9 µs | 149.6 µs | 1.54 | 151.4 µs | 151.3 µs | 145.4 µs | 1.49 |
| policy | plan | 10.0 µs | 29.7 µs | 29.4 µs | 2.95 | 29.8 µs | 29.2 µs | 29.5 µs | 2.96 |
| policy | eval | 12.7 µs | 65.5 µs | 58.0 µs | 4.57 | 57.9 µs | 28.8 µs | 28.9 µs | 2.28 |
| comprehension-map-filter | parse | 59.7 µs | 520.6 µs | 509.7 µs | 8.53 | 149.5 µs | 513.0 µs | 148.7 µs | 2.49 |
| comprehension-map-filter | check | 74.8 µs | 102.4 µs | 100.9 µs | 1.35 | 101.7 µs | 100.6 µs | 100.2 µs | 1.34 |
| comprehension-map-filter | plan | 5.1 µs | 14.4 µs | 14.3 µs | 2.78 | 14.4 µs | 14.1 µs | 14.2 µs | 2.76 |
| comprehension-map-filter | eval | 549.6 µs | 1.45 ms | 1.37 ms | 2.49 | 1.38 ms | 898.8 µs | 1.91 ms | 3.48 |
| comprehension-nested | parse | 35.1 µs | 421.6 µs | 413.1 µs | 11.76 | 86.5 µs | 412.1 µs | 90.2 µs | 2.57 |
| comprehension-nested | check | 17.3 µs | 28.0 µs | 27.6 µs | 1.60 | 27.9 µs | 27.4 µs | 27.1 µs | 1.56 |
| comprehension-nested | plan | 3.0 µs | 9.1 µs | 8.9 µs | 2.97 | 8.9 µs | 8.9 µs | 8.8 µs | 2.94 |
| comprehension-nested | eval | 946.9 µs | 3.12 ms | 3.12 ms | 3.29 | 3.13 ms | 1.56 ms | 1.56 ms | 1.65 |
| string-ops | parse | 55.2 µs | 449.1 µs | 430.4 µs | 7.80 | 114.1 µs | 431.6 µs | 113.1 µs | 2.05 |
| string-ops | check | 52.6 µs | 78.1 µs | 78.3 µs | 1.49 | 78.9 µs | 77.7 µs | 77.7 µs | 1.48 |
| string-ops | plan | 4.0 µs | 12.3 µs | 12.3 µs | 3.08 | 12.2 µs | 12.2 µs | 12.2 µs | 3.07 |
| string-ops | eval | 10.5 µs | 44.0 µs | 39.5 µs | 3.78 | 39.6 µs | 21.4 µs | 21.8 µs | 2.09 |
| long-or | parse | 444.9 µs | 1.66 ms | 1.51 ms | 3.40 | 1.30 ms | 1.48 ms | 1.29 ms | 2.91 |
| long-or | check | 692.8 µs | 381.9 µs | 382.7 µs | 0.55 | 384.0 µs | 374.7 µs | 372.1 µs | 0.54 |
| long-or | plan | 23.7 µs | 62.9 µs | 64.0 µs | 2.71 | 63.6 µs | 64.6 µs | 63.3 µs | 2.68 |
| long-or | eval | 2.6 µs | 13.5 µs | 13.2 µs | 5.07 | 13.7 µs | 6.7 µs | 6.6 µs | 2.54 |

Back-to-back A/B runs (in the commit messages) measured the main changes more precisely than this table:
policy eval 0.88×, string-ops eval 0.85× (UTF-8 buffers); parse 0.94× to 0.97× on small inputs, policy
0.87×, long-or 0.67× (token text).

## Where the time goes

- **Parse** (8× cel-go on main): about half is ANTLR adaptive prediction rebuilding the prediction DFAs
  that antlr4-go keeps in a process-wide static cache; with the cache warm (shared cache branch) parsing is
  2–3× cel-go, the remainder being parse-tree and token allocation and release (ARC frees the per-parse
  tree eagerly, about a fifth of the profile) and the thread hop `LargeStack` makes for inputs with many
  operators.
- **Check** (1.3–2× cel-go, faster on `long-or`): no single hotspot.
- **Plan** (about 3× cel-go): node and attribute allocation, `Expr.depth`, and freeing the previous
  program; cel-go plans into a garbage-collected graph.
- **Eval** (2.5–5.5× cel-go on main): copying `Value`. With 40-byte existential payloads `Value` is
  41 bytes (stride 48), and every copy or destroy of any `Value`, even an `int`, goes through the outlined
  value witness (`initializeWithCopy for Value`, `destroy for Value`): 20–30% of every eval profile, more
  around attribute resolution and comprehension variables. The rest is ARC traffic, dynamic exclusivity
  checks on the comprehension `Folder`'s stored properties, `as?` casts and runtime type guards.

## Decisions for the maintainer

Both prototypes pass the full test suite and conformance; neither is on main.

### (a) Boxed list, map, object and error payloads in `Value` (`perf/class-payloads`)

The prototype marks `.list`, `.map`, `.object` and `.error` `indirect`: Swift stores those payloads in a
heap box, `Value` becomes 17 bytes (stride 24) with only references or trivial data in its payloads, and
copying a list is one retain instead of an existential buffer copy. Eval gets 1.4–2× faster across the board (policy 58.0 → 28.8 µs, comprehension-nested
3.12 → 1.56 ms, arith 1.1 µs → 643 ns), bringing eval to 1.7–3× cel-go. Constructing one of those values
costs one more allocation.

The change is source compatible: the case list, `ListValue` / `MapValue` / `ObjectValue`, `ArrayList` and
`OrderedMap` are unchanged, so clients pattern match exactly as before. It is a layout change of a public
enum, invisible to source but part of the ABI (relevant only with library evolution, which this package
does not enable). Going further (final classes in place of the existentials, dropping `as? ArrayList`
casts) would change the public collection API and is not prototyped.

### (b) Shared ANTLR prediction cache (`perf/shared-parser-cache`)

The prototype moves the per-parse `decisionToDFA` into `PredictionCache.shared`, an `@unchecked Sendable`
final class guarded by a pthread mutex (`Synchronization.Mutex` needs macOS 15 / iOS 18), and runs all of
`adaptivePredict` under the lock. Single-threaded parse becomes 3–5× faster (policy 1.06 ms → 461 µs,
comprehension-nested 422 → 87 µs), 2–3× cel-go. A test parses concurrently from 16 tasks and compares with
sequential parses.

Costs: this is the only global mutable state in `CEL` (CLAUDE.md asks to raise it), the cache grows with the
variety of inputs (as in cel-go, never trimmed), and the coarse lock serializes prediction: with 8 threads
parsing `arith` at once (`--threads 8`) the prototype managed one parse per 135 µs of wall time against
92 µs on a single thread, so concurrent parsers run slower together than one alone (main, without the
lock, did 210 µs per parse with 8 threads against about 295 µs on one, on the same heavily loaded machine). antlr4-go locks per DFA operation (`stateMu`, `edgeMu`)
and computes target states outside the lock; porting that finer locking is the step before main.

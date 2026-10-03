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
- A change's impact: `tools/bench/bench.py --baseline-driver <main checkout>/.build/release/CELBenchmarks`
  runs a build of `main` (a second worktree) and the branch alternately (`--passes`, default 3) and keeps each
  one's fastest result, so machine load affects both alike. Every performance pull request carries this
  table and adds a row to the change log below.
- Allocations: `tools/bench/allocs.py` (macOS) runs the driver with `--iterations 0` and `--iterations n`
  under a malloc-counting interposer (`tools/bench/malloc-count`) and prints allocations per operation,
  which do not depend on machine load. The cel-go driver prints its allocations as the fourth column.
- Profiling: `tools/bench/profile.py --phase <phase> [--filter <case>]` (macOS) records the driver with
  Instruments' Time Profiler (`xctrace`) and prints time by leaf category (retain/release, malloc/free,
  exclusivity checks, dynamic casts, hashing, ...), self and inclusive time per function, and the first
  caller outside the runtime of the ARC and allocator work; `--focus <frame>` limits it to samples under a
  frame, `--callers <regex>` breaks down who calls a leaf. The trace stays in `.build/profile/` for
  Instruments. Run one recording at a time: concurrent `xctrace` sessions hang.

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

- **Parse** (1.1–1.3× cel-go; 2.3–2.9× before the changes below, 8× before the prediction cache was
  shared): freeing the parse tree is about a quarter of the profile, since ARC frees it eagerly inside the
  call while cel-go's collector frees it later. The parse tree used to cost much more: a weak `parent`
  gave every context a side table, which sent all its retains and releases through the slow path (over a
  third of parsing); dynamic exclusivity checks on the runtime's token stream took an eighth; inputs with
  more than 32 operators moved to a new thread even on a thread with megabytes of stack left. Parsing
  allocates fewer objects than cel-go (`tools/bench/allocs.py`).
- **Check** (0.8–1.1× cel-go, 0.4× on `long-or`; 1.3–1.9× before the changes below): overload resolution,
  mostly real unification work, is about 40% of `policy`. Before, a large share went to formatting types into
  strings: `TypeMapping.find` formatted every type it looked up and non-generic overloads built a function
  type per candidate. Each check also built a `Set` of all expression ids twice (`AST.nodeCount`,
  `clearUnusedIDs`), and a failed unification copied the whole type mapping, which made long expressions
  quadratic.
- **Plan** (about 3× cel-go): node and attribute allocation, `Expr.depth`, and freeing the previous
  program; cel-go plans into a garbage-collected graph.
- **Eval** (1.6–3.3× cel-go): before the payload change, copying `Value` dominated: with 40-byte
  existential payloads `Value` was 41 bytes (stride 48), and every copy or destroy of any `Value`, even an
  `int`, went through the outlined value witness (`initializeWithCopy for Value`, `destroy for Value`),
  20–30% of every eval profile. With the boxed payloads `Value` is 17 bytes (stride 24). What remains is
  ARC traffic, dynamic exclusivity checks on the comprehension `Folder`'s stored properties, `as?` casts and
  runtime type guards.

## Change log

Performance pull requests since 0.1.0, each measured against the `main` it merged into with
`tools/bench/bench.py --baseline-driver` (Apple M1 Max; ranges are after/before over the benchmark cases).

| pull request | change | parse | check | plan | eval |
|---|---|---:|---:|---:|---:|
| bench tools | `--iterations`, `--baseline-driver`, `allocs.py`, `profile.py` | - | - | - | - |
| parser | unowned parent, unchecked exclusivity, no thread hop with stack to spare, shared label slots | 0.43–0.48 | 1.00 | 1.00 | 0.97–1.00 |
| checker | type lookups without formatting, id bitset, undone failed unifications, fewer alias lookups | 1.00 | 0.55–0.73 | 1.00 | 1.00 |

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

### (b) Shared ANTLR prediction cache: landed

Each `Parser` (so each `Environment`, shared with its copies and the environments `extending` it) owns a
`PredictionCache` holding the prediction DFAs that were rebuilt for every parse before; antlr4-go keeps them
in a process-wide static. Locking is antlr4-go's: read-write locks around DFA state lookup and insertion
and around edge reads and updates, target states computed outside them (`docs/decisions.md` § 9).

Parse, before (`ea241f9`) and after, `tools/bench/bench.py --swift-only --phase pa --rounds 9 --threads n`
(`--threads` runs the phase on n threads at once; the time is wall time per parse), best of 3 interleaved
passes under load average 90 to 190 on 10 cores, so the 4- and 8-thread rows mostly show how little CPU
the machine had to spare:

| case | 1 thread before | after | 4 threads before | after | 8 threads before | after |
|---|---:|---:|---:|---:|---:|---:|
| arith | 290.9 µs | 93.0 µs | 166.9 µs | 38.7 µs | 209.0 µs | 37.7 µs |
| select-chain | 506.2 µs | 167.5 µs | 334.2 µs | 66.9 µs | 384.2 µs | 63.4 µs |
| literals | 555.4 µs | 198.7 µs | 279.9 µs | 79.4 µs | 404.0 µs | 69.8 µs |
| policy | 944.9 µs | 461.9 µs | 513.5 µs | 223.3 µs | 631.0 µs | 292.9 µs |
| comprehension-map-filter | 501.8 µs | 151.4 µs | 343.9 µs | 64.3 µs | 331.2 µs | 57.6 µs |
| comprehension-nested | 412.4 µs | 88.0 µs | 349.1 µs | 34.2 µs | 342.3 µs | 32.5 µs |
| string-ops | 436.1 µs | 115.4 µs | 339.1 µs | 49.2 µs | 336.3 µs | 46.9 µs |
| long-or | 1.44 ms | 1.29 ms | 716.7 µs | 623.0 µs | 765.8 µs | 763.8 µs |

Single-threaded parse is 2 to 5 times faster, 2–3× cel-go. With several threads the cache is shared and
still scales: 4 threads parse 2 to 2.6 times as many expressions as one (main: 1.2 to 2 times). The
coarse-lock prototype (`perf/shared-parser-cache`, all of `adaptivePredict` under one mutex) measured in
the same session ran slower with threads than alone (arith 92 µs on one thread, 100 µs per parse on 8;
fine locking 41 µs), and the same fine locking with plain mutexes in place of the read-write locks got
1.7 to 2.7 times slower than the read-write locks at 8 threads (arith 101 against 39 µs). `long-or` gains
little: its time is in parse-tree allocation and the `LargeStack` thread hop, not in prediction.

Memory: the cache grows with the variety of parsed inputs and is never trimmed (as in cel-go), and it is
freed with the environments using it; `DFA.deinit` breaks the edge cycles. Replaying the parser fuzz
corpus 5 times through `cel-fuzz-leakcheck` (whose parsers keep their caches) holds RSS at 16 MB from the
first round on, and `leaks --atExit` reports no leaks for the parser and checker targets.

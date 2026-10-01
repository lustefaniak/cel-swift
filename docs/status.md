# Status and next steps

Handoff for the next working session. Update it when a milestone moves; `docs/plan.md` has the milestones and exit
criteria, `docs/architecture.md` the design, `docs/divergences.md` every deliberate difference from cel-go.

Snapshot: 2026-10-01; the API, CLI and docs rows after `bd4f5d0`.

## Conformance (cel-spec v0.25.3)

2473 / 2508 checked, 2310 / 2339 parse-only, `Tests/CELConformanceTests/skip.txt` is empty.
Run `python3 tools/dashboard/dashboard.py --run` for the per-file table against cel-go, cel-rust and cel-cpp.

**cpp parity reached** (checked mode): every test cel-cpp passes, cel-swift passes. The ten cel-go skips that the spec
and cel-cpp pass were closed by following the spec, each recorded in `docs/divergences.md`: duration
`getMilliseconds` is the milliseconds portion; an optional met mid-path is selected into; list/map literals join `null`
into a nullable type and a primitive into its wrapper; `indexOf` / `lastIndexOf` offsets past the end are errors (cel-go
returns -1 pending a spec update, revisit on the next cel-spec bump); `ip()` accepts the hexadecimal IPv4-mapped form as
the IPv4 address; the conformance matcher accepts a check error carrying an expected eval_error message
(`network_ext/ip_type/is_ip_cidr_compile_error`).

What still fails: only the `enums` strong-enum sections (35 checked, 29 parse-only), which cel-go and cel-cpp skip
too. cel-rust "passes" 6 of them (`convert_int_too_big` / `_too_neg` / `convert_string_bad`, which expect an error that
it raises for an unrelated reason); that is the whole remaining rust gap.

## Done (on main)

| Area | Where | Notes |
|---|---|---|
| Parser, AST, macros, unparser, debug printer | `Sources/CEL/Parser`, `AST`, `Common` | byte-identical to cel-go incl. ANTLR error text; ANTLR runtime parts ported |
| Values, types, stdlib, decls, containers, time zones | `Sources/CEL/Values`, `Types`, `Stdlib`, `Decls`, `Containers` | Go float/duration/RFC 3339 formatting pinned by fixtures; TZif reader |
| Checker | `Sources/CEL/Checker` | all 142 `checker_test.go` cases |
| Interpreter | `Sources/CEL/Interpreter` | planner, attributes, unknown patterns, state, runtime cost, prune (residual ASTs) |
| Cost and limits | `Sources/CEL/Checker/Cost*`, `Interpreter`, `LimitsTests` | static estimator (96 cases), runtime cost (77), cost/time/cancellation/size limits |
| Public API (M8 API work) | `Sources/CEL/API`, `Sources/CEL/CEL.docc` | `Environment` → `compile` → `Program` → `evaluate`; partial evaluation and `residual(of:state:)`, `estimateCost`, `globals`; `Library.standard(subset:)`; `optimize` with constant folding and inlining; DocC catalog with a getting-started article whose examples run in `APIDocumentationTests`. Ported through the public API: `cel_test.go` (45 tests), `env_test.go`, `decls_test.go`, `folding_test.go` (all tables), `inlining_test.go`; each test file's header lists what was left out and why. Full suite passes in a `swift:6.0-noble` container (Linux CI installs `tzdata-legacy` for the US/Central conformance tests) |
| Command line | `Sources/cel-swift` | `cel-swift eval / check / parse [--debug] / repl / policy test`; stdlib-only argument parsing |
| Extensions | `Sources/CELExtensions`, `Sources/CEL/Library` | all cel-go ext libraries and macros, validators |
| Extension costs (M4) | `Sources/CELExtensions/*Costs.swift`, `Tests/CELExtensionsTests/{CostTable,ExtensionCost}Tests.swift` | static estimators and runtime trackers of strings (v5), lists (v3, with the v3 legacy estimates), math (v3), sets, encoders (v1), network, regex; IP/CIDR values sized in the core runtime cost; cel-go's wrapping size arithmetic kept. Ported: every cost table of `ext/*_test.go` (158 rows via `tools/ext-fixtures/extract_cost_tables.py`, whose `--verify` checks each row against the oracle), the format tables' cost fields (99 rows), the network, quote, cost-limit, `json.encode` and base64 cost tests, plus oracle-checked edge cases |
| Regex | `Sources/CELRegex` | Go regexp port, Go test tables |
| Protobuf | `Sources/CELProtobuf`, `protoc-gen-cel-swift` | generated adapters, WKTs, proto2/3, extensions |
| Policy (M7) | `Sources/CELPolicy`, `Sources/CELTest`, `Sources/CELCommandLine` | YAML parser, env configs, compiler + composer, celtest runner, `cel-swift policy test`; every cel-go policy and celtest suite passes, and `tools/celtest-go/compare.sh` shows cel-go celtest and `cel-swift policy test` agree on all of them. Not ported: textproto suites, checked-expression and descriptor-set files, coverage |
| Unknowns and state tracking (M5) | `Sources/CEL/Interpreter`, `Sources/CEL/API` | partial evaluation, unknown sets, residuals (`Environment.residual(of:state:)`), state tracking and exhaustive evaluation, end to end through the public API. Ported and passing: every `interpreter_test.go` testData case except `literal_pb3_msg` (no generated `v1alpha1.Expr` types), all 83 `prune_test.go` cases, `attribute_patterns_test.go`, `TestAttributeStateTracking` and the other unknown/qualifier tests of `attributes_test.go`, `unknown_test.go`, the partial/residual tests of `cel_test.go` and `ext/comprehensions_test.go` (`TestTwoVarComprehensionsResidualAST`). `tools/partial-fixtures` pins 208 more cases (value, error, unknown ids and attribute trails, residual text; checked and parse-only) to cel-go through the oracle's `residual` flag; all match, so no divergences |
| Fuzzing | `Fuzz/`, `Sources/cel-fuzz-*`, `Sources/CELFuzzSupport` (only with `CEL_FUZZ=1`) | CI job 60 s per target, nightly workflow. Three docker runs (`--memory 8g`): ~10 + 20 + 20 min per target, about 40k parser, 200k checker and 220k evaluator executions; the only finding was the memory growth, two parser retain cycles (prediction DFA edges; rule context and its syntax error), fixed with reproducers in `FuzzRegressionTests`. Since then RSS plateaus near 1 GB per target under ASan (allocator and corpus), `cel-fuzz-leakcheck` shows flat RSS without ASan and `leaks` finds nothing over the generated corpora; see `Fuzz/README.md` § Memory. The parser target runs at ~10 exec/s: long inputs of nested unary operators cost ANTLR prediction 100+ ms (about 2× cel-go, see Performance) |
| Tooling | `tools/oracle`, `tools/dashboard`, `tools/build-guard`, `tools/*-fixtures` | cel-go oracle (parse/check/eval, unknowns, residuals), dashboard, build memory guard, fixture generators |

## Next, in order

Each item is sized for one fresh session. Read `CLAUDE.md` first; every build goes through `tools/build-guard/swiftlock`.

1. **Differential suite (M4)** — not started. Seeded generator of well-typed expressions, batch through `tools/oracle`,
   compare value / error / type / static cost / runtime cost, minimise failures into a checked-in regression file, wire
   the nightly slot in `.github/workflows/nightly.yml`.
2. **Public API follow-ups (M8)** — move the policy composer's internal optimizer
   (`Sources/CELPolicy/Compiler/StaticOptimizer.swift`) onto `Environment.optimize` and drop the copy; run
   `swift package diagnose-api-breaking-changes` once a tag exists; decide the open questions below, which block
   custom macros, custom optimizers and decorators, proto AST conversion and the cel-go tests that need them
   (listed in the headers of `Tests/CELTests/API*Tests.swift`). The public `enum CEL` (only `specVersion`) shares
   the module's name, which breaks `CEL.Environment`-style qualification for clients; rename or drop it before 1.0.
3. **Performance** — about 2–3× slower than cel-go (`swift run -c release CELBenchmarks`); `Value` copies through
   existential list/map/object payloads dominate. Parser rebuilds the ANTLR prediction cache per parse (~0.5 ms, and
   100+ ms for long inputs of nested unary operators, which keeps the parser fuzzer at ~10 exec/s);
   sharing it needs a lock in an `@unchecked Sendable` class (CLAUDE.md asks to raise that first).
4. **Strong enums (optional, beyond cpp parity)** — the last 35 conformance tests (`enums/strong_proto2`,
   `strong_proto3`). Needs an environment option (the `legacy_*` sections must keep passing), a typed enum value and
   type (a public `Value` / `CELType` decision: new case or opaque type), enum type names resolving to types and to
   conversion functions `E(int)` / `E(string)` with int32 range and name checks, `CELProtobuf` field reads and writes
   producing and accepting enum values, `type()`, equality and `int()` on them, and `enum_value` in the conformance
   value conversion. About one session after the API decision; cel-go and cel-cpp do not implement it either.

## Open decisions for the maintainer

- Public AST (needed for custom macros and validators in the public API)?
- Conversion of parsed/checked expressions to and from the cel-spec protos (the types live in a non-product target)?
- `Value` accessor naming: `asInt` (current) or `intValue`?
- Class-backed list/map/object payloads in `Value` for copy performance?
- Package name `cel-swift` vs `swift-cel` before the first tag.

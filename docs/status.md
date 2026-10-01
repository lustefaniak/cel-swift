# Status and next steps

Handoff for the next working session. Update it when a milestone moves; `docs/plan.md` has the milestones and exit
criteria, `docs/architecture.md` the design, `docs/divergences.md` every deliberate difference from cel-go.

Snapshot: 2026-10-01; the API, CLI and docs rows after `bd4f5d0`, the differential suite after `4fa57ff`.

## Conformance (cel-spec v0.25.3)

2508 / 2508 checked, 2339 / 2339 parse-only (100%), `Tests/CELConformanceTests/skip.txt` is empty.
Run `python3 tools/dashboard/dashboard.py --run` for the per-file table against cel-go, cel-rust and cel-cpp.

**cpp parity reached** (checked mode): every test cel-cpp passes, cel-swift passes. The ten cel-go skips that the spec
and cel-cpp pass were closed by following the spec, each recorded in `docs/divergences.md`: duration
`getMilliseconds` is the milliseconds portion; an optional met mid-path is selected into; list/map literals join `null`
into a nullable type and a primitive into its wrapper; `indexOf` / `lastIndexOf` offsets past the end are errors (cel-go
returns -1 pending a spec update, revisit on the next cel-spec bump); `ip()` accepts the hexadecimal IPv4-mapped form as
the IPv4 address; the conformance matcher accepts a check error carrying an expected eval_error message
(`network_ext/ip_type/is_ip_cidr_compile_error`).

Nothing fails. The `enums` strong-enum sections (35 checked, 29 parse-only), which cel-go and cel-cpp skip, pass with
`Environment.Option.strongEnums` (off by default, so the `legacy_*` sections pass too; the runner enables it for the
strong sections). Enum values are `EnumValue` objects with an opaque enum type (decision 7).

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
| Release prep (M8) | `tools/check-headers`, `tools/check-docs`, `tools/api-check`, `CHANGELOG.md`, `docs/decisions.md`, `.github/workflows/ci.yml` | every file under `Sources` carries its license header and names its cel-go / Go / ANTLR / go-yaml source (`check_headers.py`, CI); every public declaration has a doc comment and the `CEL` and `CELPolicy` DocC catalogs build with `--warnings-as-errors` (`check-docs.sh`, CI); `check-api.sh` runs `diagnose-api-breaking-changes` against the last tag (CI, report-only before 1.0); CI adds Linux Swift 6.2 / 6.3, an iOS simulator build and a static Linux SDK (musl) build; the policy composer runs on the core `Environment.optimize` |
| Differential suite (M4) | `Tests/CELDifferentialTests`, nightly `differential` job | seeded, type-directed generator (all core types, optionals, dyn, nested comprehensions and two-variable macros, every extension library including network, the conformance TestAllTypes messages, partial evaluation patterns, cost limits, parse-only mode, random extension versions, one-character syntax mutations) run through `tools/oracle` and cel-swift's public API; compares value, error message, deduced type, static cost range and runtime cost, extension costs included. `swift test` runs 8 fixed seeds x 100 cases (~2 s, skipped with a message without Go); the nightly job runs 20 random seeds x 2500 on Linux. Failures are rerun on cel-go (random map order), minimised and appended to `regressions.jsonl`, which stores cel-go's answer and runs without Go. About 600k cases run during development found 7 cel-swift bugs (fixed, each with a reproducer in the regression file); the final 50k run was clean. Documented divergences and cel-go quirks it excuses are listed in `Mismatch.divergences`; open gaps in `KnownGaps` (below) |
| Tooling | `tools/oracle`, `tools/dashboard`, `tools/build-guard`, `tools/*-fixtures` | cel-go oracle (parse/check/eval, unknowns, residuals), dashboard, build memory guard, fixture generators |

## Next, in order

Each item is sized for one fresh session. Read `CLAUDE.md` first; every build goes through `tools/build-guard/swiftlock`.

1. **First release (M8)** — the questions in `docs/decisions.md` are decided and applied except the one being
   implemented (shared parser cache); `CHANGELOG.md` has the 0.1.0 section. When those land: update
   the changelog numbers, tag `0.1.0` and point PRBar at it. From then on `tools/api-check/check-api.sh` compares
   against the tag. Custom macros, optimizers and decorators, proto AST conversion and the cel-go tests that need
   them (headers of `Tests/CELTests/API*Tests.swift`) wait for a public AST facade (decision 3).
2. **Performance** — baseline and method in `docs/performance.md` (`tools/bench/bench.py` runs the same
   expressions through cel-swift and cel-go, parse / check / plan / eval). On main: parse about 8× cel-go,
   check 1.3–2×, plan about 3×, eval 1.6–3.3× (after the boxed `Value` payloads, decision 6). The shared ANTLR
   prediction cache with antlr-go's per-DFA locking is being implemented (decision 9; the coarse-lock prototype
   `perf/shared-parser-cache` made parse 3–5× faster single-threaded).
   Remaining without a decision: plan allocation, `Folder` exclusivity checks, `LargeStack`'s thread hop for
   long inputs.

## After the port

- **Swift ergonomics module** (maintainer direction, name open: `CELSwift` / `CELErgonomics`): idiomatic
  Swift on top of the core, using `Codable` activations and result decoding, result builders or macros for
  declarations and custom functions, typed function bindings via generics / parameter packs,
  `ExpressibleBy*Literal` conformances, async evaluation, macro- or property-wrapper-driven environments.
  The core `CEL` module stays close to cel-go's shape; ergonomic API choices go there
  (`docs/decisions.md`, introduction). Subsumes the `@CELType` macro of `docs/plan.md`.

## Open differential gaps

Found by the differential suite and not fixed; the generator steers around them (`KnownGaps` in
`Tests/CELDifferentialTests/Generator.swift`), and the regression file keeps a reproducer where one applies.

- **Proto2 enums are closed in SwiftProtobuf.** `proto2.TestAllTypes{standalone_enum: 10}` (and enum lists and map
  values) fails with `invalid enum value 10 for NestedEnum`; cel-go stores the number. Needs proto2 enum fields to
  carry unknown numbers (generated adapters or a raw-value path), or a documented divergence.
- **Error naming of a null read from a wrapper field**: cel-go says `structpb.NullValue`, cel-swift `types.Null`
  (`invalid qualifier type: ...`); cel-swift has one null value. Excused in the comparison.
- **cel-go bug, not ours**: the runtime cost trackers of `ext/lists.go` `distinct` and `sort` cast their argument to a
  list without checking for an error, so `[1/0].distinct()`-style errors panic in cel-go (recovered as `internal
  error: interface conversion ...`). cel-swift returns the argument's error. Excused in the comparison.
- **Program creation errors**: cel-go's `Env.Program` returns a plain error (`no such overload: f()`), cel-swift a
  `CompileError` whose description renders it as `ERROR: <input>:-1:0: ...`; the suite compares the messages.

## Decisions

`docs/decisions.md` records what was decided before 0.1.0 and why.

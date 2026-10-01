# Status and next steps

Handoff for the next working session. Update it when a milestone moves; `docs/plan.md` has the milestones and exit
criteria, `docs/architecture.md` the design, `docs/divergences.md` every deliberate difference from cel-go.

Snapshot: 2026-10-01; the API, CLI and docs rows after `bd4f5d0`.

## Conformance (cel-spec v0.25.3)

2461 / 2508 checked, 2304 / 2339 parse-only, 14 entries in `Tests/CELConformanceTests/skip.txt` (each with reason).
Run `python3 tools/dashboard/dashboard.py --run` for the per-file table against cel-go, cel-rust and cel-cpp.

What still fails or is skipped:
- `enums` strong-enum tests (35): deferred by design, cel-go and cel-cpp skip them too.
- `type_deduction`: 5 skipped exactly as cel-go skips them.
- `string_ext` 2, `network_ext` 3: skipped with reasons (cel-go skips / rejects the same inputs).
- A few cel-go-skipped singles (`timestamps` get_milliseconds, `optionals` map_optional_select_has).

Parity is not reached yet: the dashboard reports 10 tests cel-rust passes and 8 cel-cpp passes (checked mode) that we
fail or skip. They are all cases where cel-swift follows cel-go (which skips them) while the spec and the other
implementations pass: `timestamps/duration_converters/get_milliseconds`, `optionals/.../map_optional_select_has`,
`string_ext/value_errors/{indexof,lastindexof}_out_of_range`, the three skipped `network_ext` tests, and the
`type_deductions` legacy-nullable / wrapper-promotion cases. Closing them means a deliberate divergence from cel-go
toward the spec, each recorded in `docs/divergences.md` (plan: cpp parity is the bar).

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
| Regex | `Sources/CELRegex` | Go regexp port, Go test tables |
| Protobuf | `Sources/CELProtobuf`, `protoc-gen-cel-swift` | generated adapters, WKTs, proto2/3, extensions |
| Policy (M7) | `Sources/CELPolicy`, `Sources/CELTest`, `Sources/CELCommandLine` | YAML parser, env configs, compiler + composer, celtest runner, `cel-swift policy test`; every cel-go policy and celtest suite passes, and `tools/celtest-go/compare.sh` shows cel-go celtest and `cel-swift policy test` agree on all of them. Not ported: textproto suites, checked-expression and descriptor-set files, coverage |
| Fuzzing | `Fuzz/`, `Sources/cel-fuzz-*` (only with `CEL_FUZZ=1`) | CI job 60 s per target, nightly workflow |
| Tooling | `tools/oracle`, `tools/dashboard`, `tools/build-guard` | cel-go oracle, dashboard, build memory guard |

## Next, in order

Each item is sized for one fresh session. Read `CLAUDE.md` first; every build goes through `tools/build-guard/swiftlock`.

1. **Differential suite (M4)** — not started. Seeded generator of well-typed expressions, batch through `tools/oracle`,
   compare value / error / type / static cost / runtime cost, minimise failures into a checked-in regression file, wire
   the nightly slot in `.github/workflows/nightly.yml`.
2. **Extension cost functions (M4)** — cel-go's per-library estimators/trackers for strings, lists, math, sets,
   encoders, network, regex into the `Library.costEstimateOptions` / `costTrackers` hooks; cel-go counts IP/CIDR as
   sized; several cel-go size formulas wrap on overflow (use `&+`/`&*` there).
3. **Fuzzing follow-up** — run each fuzzer 15+ min in docker (`--memory 8g`); investigate memory growth (700–800 MB and
   rising per fuzzer in the first run).
4. **Public API follow-ups (M8)** — move the policy composer's internal optimizer
   (`Sources/CELPolicy/Compiler/StaticOptimizer.swift`) onto `Environment.optimize` and drop the copy; run
   `swift package diagnose-api-breaking-changes` once a tag exists; decide the open questions below, which block
   custom macros, custom optimizers and decorators, proto AST conversion and the cel-go tests that need them
   (listed in the headers of `Tests/CELTests/API*Tests.swift`). The public `enum CEL` (only `specVersion`) shares
   the module's name, which breaks `CEL.Environment`-style qualification for clients; rename or drop it before 1.0.
5. **Unknowns and state tracking (M5)** — interpreter pieces exist (attribute patterns, prune, eval state); port the
   remaining cel-go unknowns tests end to end through the public API.
6. **Parity gap** — the spec-over-cel-go cases listed under Conformance; decide each, fix, record the divergence.
7. **Performance** — about 2–3× slower than cel-go (`swift run -c release CELBenchmarks`); `Value` copies through
   existential list/map/object payloads dominate. Parser rebuilds the ANTLR prediction cache per parse (~0.5 ms);
   sharing it needs a lock in an `@unchecked Sendable` class (CLAUDE.md asks to raise that first).

## Open decisions for the maintainer

- Public AST (needed for custom macros and validators in the public API)?
- Conversion of parsed/checked expressions to and from the cel-spec protos (the types live in a non-product target)?
- `Value` accessor naming: `asInt` (current) or `intValue`?
- Class-backed list/map/object payloads in `Value` for copy performance?
- Package name `cel-swift` vs `swift-cel` before the first tag.

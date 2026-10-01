# Status and next steps

Handoff for the next working session. Update it when a milestone moves; `docs/plan.md` has the milestones and exit
criteria, `docs/architecture.md` the design, `docs/divergences.md` every deliberate difference from cel-go.

Snapshot: 2026-10-01, `main` after `edae596`.

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
| Public API | `Sources/CEL/API` | `Environment` → `compile` → `Program` → `evaluate`; partial evaluation, `estimateCost` |
| Extensions | `Sources/CELExtensions`, `Sources/CEL/Library` | all cel-go ext libraries and macros, validators |
| Regex | `Sources/CELRegex` | Go regexp port, Go test tables |
| Protobuf | `Sources/CELProtobuf`, `protoc-gen-cel-swift` | generated adapters, WKTs, proto2/3, extensions |
| Policy YAML parser, env config and tests.yaml models | `Sources/CELPolicy`, `Sources/CELTest` | parser half of M7 |
| Fuzzing | `Fuzz/`, `Sources/cel-fuzz-*` (only with `CEL_FUZZ=1`) | CI job 60 s per target, nightly workflow |
| Tooling | `tools/oracle`, `tools/dashboard`, `tools/build-guard` | cel-go oracle, dashboard, build memory guard |

## Next, in order

Each item is sized for one fresh session. Read `CLAUDE.md` first; every build goes through `tools/build-guard/swiftlock`.

1. **Policy compiler (M7b)** — branch `wip/policy` (3 WIP commits, builds, *no tests run yet*). Contains config
   resolution (`Environment.Option.environmentConfig`), `PolicyCompiler`/`CompiledPolicy`, the composer, `TestCompiler`
   and `TestRunner`. Steps: rebase onto main; drop its `cel.@block` stand-in in
   `Sources/CELPolicy/Environment/PolicyExtensions.swift` (main evaluates `cel.@block` since `9f73cec`); run
   `PolicyCompilerTests` and fix; port `policy/config_test.go`; add CELTestTests running every `policy/testdata` and
   `tools/celtest/testdata` suite; add `cel-swift policy test`. Exit: plan M7.
2. **Differential suite (M4)** — not started. Seeded generator of well-typed expressions, batch through `tools/oracle`,
   compare value / error / type / static cost / runtime cost, minimise failures into a checked-in regression file, wire
   the nightly slot in `.github/workflows/nightly.yml`.
3. **Extension cost functions (M4)** — cel-go's per-library estimators/trackers for strings, lists, math, sets,
   encoders, network, regex into the `Library.costEstimateOptions` / `costTrackers` hooks; cel-go counts IP/CIDR as
   sized; several cel-go size formulas wrap on overflow (use `&+`/`&*` there).
4. **Fuzzing follow-up** — run each fuzzer 15+ min in docker (`--memory 8g`); investigate memory growth (700–800 MB and
   rising per fuzzer in the first run).
5. **Public API completion (M8)** — `Library.standard(subset:)` (needed by the config), port `cel/cel_test.go`,
   `env_test.go`, `decls_test.go`, `folding_test.go`, `inlining_test.go`; folding/inlining optimizers; `cel-swift` CLI
   (`eval`, `check`, `parse --debug`, `repl`); DocC catalog + README usage; Swift 6.0 Linux check in docker.
6. **Unknowns and state tracking (M5)** — interpreter pieces exist (attribute patterns, prune, eval state); port the
   remaining cel-go unknowns tests end to end through the public API.
7. **Docs debt** — interpreter and Library sections in `docs/architecture.md`; divergence notes from the extensions
   work (pre-v4 `format` locales are en-US only; invalid UTF-8 under `%s` prints U+FFFD; `NativeTypes` not ported);
   Go strings/strconv/base64/netip ports in `NOTICE`.
8. **Parity gap** — the spec-over-cel-go cases listed under Conformance; decide each, fix, record the divergence.
9. **Performance** — about 2–3× slower than cel-go (`swift run -c release CELBenchmarks`); `Value` copies through
   existential list/map/object payloads dominate. Parser rebuilds the ANTLR prediction cache per parse (~0.5 ms);
   sharing it needs a lock in an `@unchecked Sendable` class (CLAUDE.md asks to raise that first).

## Open decisions for the maintainer

- Public AST (needed for custom macros and validators in the public API)?
- Conversion of parsed/checked expressions to and from the cel-spec protos (the types live in a non-product target)?
- `Value` accessor naming: `asInt` (current) or `intValue`?
- Class-backed list/map/object payloads in `Value` for copy performance?
- Package name `cel-swift` vs `swift-cel` before the first tag.

# cel-swift implementation plan

Status: draft plan, 2026-10-01.

A pure-Swift implementation of the [Common Expression Language](https://github.com/google/cel-spec), developed
in its own repository and consumed by PRBar as an ordinary SwiftPM dependency. It ports
[cel-go](https://github.com/cel-expr/cel-go) (the reference implementation) and is measured against the official
cel-spec conformance suite.

## Goals

- **Conformance**: first at least match cel-rust, then reach cel-cpp's level (see Conformance targets).
- **Pure Swift, no native dependencies in the core**: macOS, iOS, Linux (glibc and the static musl SDK).
  No Go, no C++, no Bazel.
- **Safe for untrusted expressions**: guaranteed termination, cost estimation and runtime cost limits,
  cancellation, bounded parser recursion. Rules come from other people's repositories.
- **Feature parity with cel-go where it matters for embedding**: type checker, partial evaluation with
  unknowns, state tracking for explanations, and the CEL Policy YAML format with its test format.
- **Swift-shaped API**: Swift 6 strict concurrency, `Sendable` values, value types, no global state.

Non-goals (for 1.0): protobuf descriptor-driven dynamic messages at runtime (see Protobuf), Windows (not
blocked, just not tested), beating cel-go on performance.

## Reference points

| Source | Use |
|---|---|
| [cel-spec `doc/langdef.md`](https://github.com/google/cel-spec/blob/master/doc/langdef.md) | normative semantics |
| cel-spec `tests/simple/testdata/*.textproto` (31 files, ~2,400 tests at v0.25.3) | conformance oracle |
| cel-spec `proto/cel/expr/**` | value, checked AST and test-file schemas; conformance test messages (`TestAllTypes`, proto2 + proto3) |
| cel-go `parser`, `checker`, `interpreter`, `common`, `cel`, `ext`, `policy` | line-by-line reference for the port |
| cel-go `common/debug.ToDebugString` | exact AST comparison format for parser tests |
| cel-go `policy/testdata`, `tools/celtest` | policy conformance and test-file format |
| cel-rust `conformance/src/bin/ignored.txt` | intermediate bar |
| cel-cpp `conformance/BUILD` `_TESTS_TO_SKIP*` | final bar |

### Size of the reference (cel-go, non-test, non-generated Go)

| Package | Lines | Notes |
|---|---|---|
| `parser` | 5.4k (+7.3k generated ANTLR) | replaced by a hand-written lexer + Pratt / recursive-descent parser |
| `checker` | 2.5k | |
| `interpreter` | 8.3k | planner, attributes, unknowns, runtime cost, state tracking |
| `common/types` | 13.5k | of which ~1.5k `pb` |
| `common/ast`, `decls`, `env`, `stdlib`, `containers`, `operators`, `overloads`, `runes`, `debug` | 9.4k | |
| `common/cost` | 3.8k | static estimator |
| `cel` | 8.9k | public API and options; re-designed, not transliterated |
| `ext` | 9.8k | strings, math, lists, sets, bindings, block, encoders, network, comprehensions, formatting, regex, native |
| `policy` | 2.6k | |
| Go `regexp` + `regexp/syntax` (stdlib) | 6.5k | RE2 semantics, needed for `matches` and `ext` regex functions |

Expect the Swift result at roughly 35 to 45k lines of source, plus ported tests.

## Conformance targets

Where the two existing non-Go implementations stand at cel-spec v0.25.3:

- **cel-rust**: 1,225 of 2,507 generated tests ignored (49%). All of `basic`, `logic`, `integer_math`, `fp_math`,
  `string`, `lists`, `conversions`, `fields` pass. Fails: all of `type_deduction` (no checker), most of the
  extensions (`string_ext`, `math_ext`, `lists_ext`, `network_ext`, `block_ext`, `bindings_ext`), most protobuf
  (`proto2`, `proto3`, `enums`, `wrappers`, `dynamic`), 72 `comparisons`, 26 `parse`, 18 `optionals`.
- **cel-cpp**: about ten skipped tests, all with a reason: one deprecated spec function, a handful of
  parse-only qualified-identifier cases, strong proto enums (a future CEL 1.0 feature), two legacy US/ time
  zone cases, one double-formatting case.

Targets:

- **Milestone "rust parity"**: the set of tests cel-rust passes is a subset of the set we pass.
- **Milestone "cpp parity"**: our skip list is no longer than cel-cpp's, and every entry carries a reason and a
  linked issue.
- No test is skipped to make a number go up: an entry in the skip list requires a reason in the file, and the
  dashboard shows the list.

## Repository layout

Name: `cel-swift` (Swift packages conventionally use `swift-<name>`, e.g. `swift-protobuf`; decide before the
first tag, see Open questions).

```
Package.swift
Sources/
  CEL/                   core: AST, lexer, parser, macros, unparser, checker, types and values,
                         interpreter, standard library, cost, unknowns, state tracking. Zero dependencies.
  CELExtensions/         strings, math, lists, sets, bindings, block, encoders, network,
                         two-variable comprehensions, formatting. Depends on CEL.
  CELRegex/              port of Go regexp + regexp/syntax (RE2 semantics). Depends on nothing.
  CELProtobuf/           protobuf values and well-known types over swift-protobuf; runtime support for
                         generated message adapters. Depends on CEL + SwiftProtobuf.
  CELPolicy/             CEL Policy YAML: parser with source positions, compiler, match / aggregate.
                         Depends on CEL + Yams.
  CELTest/               celtest-compatible `tests.yaml` runner as a library.
  protoc-gen-cel-swift/  protoc plugin emitting CEL message adapters for swift-protobuf types.
  cel-swift/             CLI: `eval`, `check`, `parse --debug`, `policy test`, `repl`.
Tests/
  CELTests/              unit tests ported from cel-go, per package
  CELConformanceTests/   cel-spec simple tests (submodule), generated conformance protos
  CELPolicyTests/        cel-go policy testdata
  CELDifferentialTests/  driver for the cel-go oracle
tools/
  oracle/                small Go program: reads JSONL cases, evaluates with cel-go, writes results.
                         CI and dev only, never part of the package.
  dashboard/             per-file pass table against cel-rust and cel-cpp
third_party/
  cel-spec/              git submodule pinned to a release tag
docs/                    DocC catalog
CLAUDE.md                porting rules for agents (see Working method)
NOTICE                   cel-go and cel-spec attribution
```

`CEL` has no dependencies so a consumer that never touches protobuf or YAML (PRBar's engine) pulls in nothing
else. Swift tools version 6.0, language mode 6, `SWIFT_STRICT_CONCURRENCY = complete`.

Platforms: macOS 13+, iOS 16+, Linux (Swift 6.x toolchains, glibc; plus a CI build with the static Linux SDK).
Foundation use in `CEL` is limited to what `FoundationEssentials` provides on Linux (`TimeZone`, `Data` where
unavoidable); the core value types do not depend on `Date`.

## Architecture

### Values

```swift
public enum Value: Sendable {
  case null
  case bool(Bool)
  case int(Int64)
  case uint(UInt64)
  case double(Double)
  case string(String)        // operations work on unicodeScalars, never Characters
  case bytes(Bytes)          // [UInt8] wrapper
  case list(any ListValue)
  case map(any MapValue)
  case type(CELType)
  case duration(Duration)    // seconds + nanos, CEL range
  case timestamp(Timestamp)  // seconds + nanos, 0001-01-01 to 9999-12-31
  case optional(Value?)
  case object(any ObjectValue)  // protobuf messages, native Swift types
  case error(EvalError)
  case unknown(UnknownSet)
}
```

- Lists and maps are protocols so host data (JSON, Swift arrays and dictionaries, protobuf repeated fields)
  is adapted lazily, not copied. Concrete `ArrayList` / `DictionaryMap` for literals.
- Map keys: `bool`, `int`, `uint`, `string`, with CEL's cross-numeric key equality (`1 == 1u` as keys).
- `ObjectValue` is how protobuf messages and native Swift types (via a later `@CELType` macro) appear: field
  lookup by name, presence test, type name.
- Errors and unknowns are values, so commutative `&&` / `||` and the error-absorption rules fall out of
  ordinary evaluation.

### Types

- `CELType`: primitives, `list(T)`, `map(K, V)`, `type(T)`, `dyn`, `null_type`, `error`, wrappers,
  `opaque(name, params)`, type parameters, `message(name)`, `optional_type(T)`.
- Declarations: variables, functions with overloads (argument types, return type, type params,
  receiver-style flag), containers, abbreviations, aliases.
- A `TypeProvider` protocol resolves message types and fields (implemented by `CELProtobuf` and by native types).

### Parser

- Hand-written lexer and parser following `CEL.g4` precedence: conditional, `||`, `&&`, relations, additive,
  multiplicative, unary, member (select, index, call, optional select `.?`, optional index `[?`), primary
  (identifiers with leading-dot, literals, list / map / message construction).
- Literal parsing to spec: all string forms (single / double / triple quoted, raw, escapes including `\u`,
  `\U`, octal, hex), bytes, int / uint / double including hex and edge ranges.
- AST with stable expression ids, `SourceInfo` (offsets, line starts), macro call map for unparsing.
- Macro expansion to comprehension nodes exactly as cel-go: `has`, `all`, `exists`, `exists_one`, `map`
  (2 and 3 arg), `filter`, plus extension macros (`cel.bind`, `cel.block`, two-variable comprehensions,
  optional `.optMap` / `.optFlatMap`).
- Limits: max recursion depth, max expression code points, max error count; parse errors with cel-go's caret
  snippet format.
- `Unparser` and a port of `debug.ToDebugString`, so parser output is compared with cel-go's byte for byte.

### Checker

- Port of cel-go's checker: type inference with type parameters and substitution, overload resolution,
  `dyn` gradual typing, wrapper and null assignability, container and qualified-name resolution, optional
  types.
- Produces a checked AST: type map, reference map (resolved overload ids and qualified names).
- `type_deduction.textproto` is the conformance target here (cel-rust passes none of it).

### Interpreter

- Planner turns a checked (or parse-only) AST into a tree of `Interpretable` nodes; evaluation is synchronous.
- Attribute resolution with cel-go semantics: absolute and relative names, container search order,
  longest-prefix qualified identifiers, map / object / list qualifiers.
- Short-circuit `&&`, `||`, `?:` with commutative error and unknown absorption.
- Comprehensions with an iteration budget.
- Options mirroring cel-go: exhaustive evaluation, state tracking (value of every sub-expression for
  explanations), partial evaluation (attribute patterns marked unknown; result is a value or an unknown set,
  plus a residual AST), runtime cost tracking with a limit, interrupt check every N iterations (honours
  `Task.isCancelled` and an explicit deadline).
- Constant folding as an optional optimizer pass, after conformance.

### Standard library

- Operators and overloads per spec, with int64 / uint64 overflow as errors, division and modulo by zero
  errors, NaN and infinity semantics, heterogeneous numeric equality and ordering.
- Conversions: `int`, `uint`, `double`, `string`, `bytes`, `bool`, `duration`, `timestamp`, `dyn`, `type`.
  `string(double)` must match cel-go's formatting; Swift's shortest round-trip printing differs in exponent
  format, so this is a dedicated formatter with differential tests.
- Strings: `size`, `contains`, `startsWith`, `endsWith`, `matches` (via `CELRegex`), all on Unicode scalars.
- Timestamps and durations: RFC 3339 parsing and printing with nanoseconds, accessors with optional IANA time
  zone (`TimeZone(identifier:)`; on Linux this requires tzdata, documented and tested in CI).

### Regex (`CELRegex`)

- Port of Go's `regexp/syntax` (parser, simplifier, compiler) and `regexp` (Pike VM, one-pass, bounded
  backtracker), ~6.5k lines of Go. RE2 syntax and linear-time matching, which CEL specifies.
- Swift `Regex` / `NSRegularExpression` are not usable: ICU syntax and backtracking, so both results and
  worst-case time differ.
- Tested with Go's own regexp test tables (`re2-search.txt`, `re2-exhaustive.txt.bz2`), which are data files
  and port directly.

### Cost

- Static estimator (port of `checker/cost.go`): per-node min/max cost with size hints for variables, custom
  function cost hooks.
- Runtime cost (port of `interpreter/runtimecost.go`): same formulas, so a cost limit means the same thing in
  cel-go and here.
- Differential tests compare both estimates and actual costs with cel-go.

### Protobuf (`CELProtobuf`)

- swift-protobuf has no descriptor-driven dynamic messages, so message access comes from code generation:
  `protoc-gen-cel-swift` emits, per message, a field table (name, number, CEL type, presence semantics),
  getters returning `Value`, and a builder for message construction expressions.
- Well-known types: `Any` (unpacking via a type registry), `Duration`, `Timestamp`, wrappers (to nullable
  primitives), `Struct` / `Value` / `ListValue` (to dynamic maps and lists), `Empty`, `FieldMask`.
- proto2 vs proto3 presence and default values, `has()` semantics, enums as ints (strong enums deferred, as
  in cel-cpp), extensions (`proto2_ext`).
- The conformance protos (`TestAllTypes`, nested types, proto2 + proto3) are generated with both
  `protoc-gen-swift` and `protoc-gen-cel-swift` and checked in under the conformance test target.

### CEL Policy (`CELPolicy`)

- Port of cel-go `policy`: YAML parsing with source positions (Yams `Node` marks), `name`, `description`,
  `imports`, `rule` with `id`, `variables` (lazily evaluated, memoised), `match` (first-match), `aggregate`,
  nested and unconditional nested rules with fallthrough, typed outputs (all outputs must agree; `optional`
  result when not exhaustive), custom tag handlers for embedder-specific fields.
- Compiles a policy to a single checked CEL AST, so every guarantee of the core (cost, unknowns, state
  tracking) applies to policies unchanged.
- Environment config YAML (variables, functions, extensions), as in cel-go's `config.yaml`.
- `CELTest`: the `tests.yaml` format (sections, named tests, `input` values or expressions, expected `output`
  value, expression or error) and a runner, compatible with cel-go's `celtest` so the same files run against
  both.

### Public API sketch

```swift
let env = try Environment(
  variables: ["pr": .map(.string, .dyn), "review": .map(.string, .dyn)],
  extensions: [.strings, .lists],
  container: "prbar"
)
let ast = try env.compile("pr.additions <= 200 && review.confidence >= 0.85")   // parse + check
let program = try env.program(ast, options: [.costLimit(10_000), .trackState])
let result = try program.evaluate(["pr": prValue, "review": reviewValue])
result.value          // Value
result.cost           // UInt64
result.state          // per-expression values, for explanations

let partial = try program.evaluate(activation, unknowns: [.attribute("signals")])
partial.unknowns      // which attributes are needed to decide
```

Errors: `CompileError` (list of issues with source locations, rendered like cel-go), `EvalError` (CEL
runtime error values surface as `.error` or are thrown at the top level, configurable).

## Testing

1. **Conformance** (`CELConformanceTests`): reads cel-spec textproto files with swift-protobuf's text format
   decoder (needs the generated `cel.expr` and conformance message types, test target only). Every test runs
   in checked mode and, unless `disable_check`, in parse-only mode too. A `skip.txt` with reasons; the
   dashboard script prints per-file pass counts next to cel-rust's and cel-cpp's.
2. **Ported unit tests** from cel-go per package: parser debug-string tables, checker tables, interpreter,
   cost, unknowns, policy.
3. **Differential testing** against cel-go: a grammar-based generator emits random well-typed expressions with
   declarations and random bindings; `tools/oracle` evaluates them with cel-go; results, error kinds, deduced
   types and costs must match. Runs on every PR with a fixed seed set and nightly with fresh seeds; failures
   are minimised and saved as regression cases.
4. **Fuzzing**: libFuzzer (`-sanitize=fuzzer`, Linux) on lexer, parser, checker and evaluator with time and
   memory caps. Any hang or crash is a bug by definition, since inputs are untrusted.
5. **Regex**: Go's RE2 test data.
6. **Benchmarks**: a small fixed set (policy-sized expressions, comprehension-heavy expressions) compared with
   cel-go, to catch pathological slowness, not to compete.

CI: macOS (latest Xcode) and Linux (Swift 6.x docker image), plus a static Linux SDK build. The oracle job
installs Go.

## Milestones

The order puts what PRBar needs first; everything after M8 is the road from rust parity to cpp parity.

| # | Milestone | Exit criteria |
|---|---|---|
| M0 | Scaffolding | Package, CI on macOS + Linux, cel-spec submodule at v0.25.3, generated conformance protos, harness loading every test file and reporting all tests as not implemented, dashboard script, Go oracle building |
| M1 | Lexer, parser, macros, unparser, debug printer | cel-go `parser_test.go` tables pass with identical debug strings; every conformance expression parses (or fails to parse) as in cel-go |
| M2 | Values, interpreter (parse-only mode), core stdlib | `basic`, `logic`, `integer_math`, `fp_math`, `string`, `lists`, `macros`, `macros2`, `conversions`, `fields` (non-proto), `namespace`, `timestamps`, non-proto `comparisons`, `plumbing` pass in parse-only mode |
| M3 | Checker | `type_deduction` passes; every M2 file also passes in checked mode. **Rust parity** reached for the non-protobuf files |
| M4 | Cost and limits | static estimator and runtime cost match cel-go in differential tests; cost limit, interrupt check, recursion and size limits; fuzzing job green for 24 h |
| M5 | Unknowns and state tracking | partial evaluation, unknown sets, residual ASTs, exhaustive evaluation; cel-go interpreter unknowns tests ported and passing |
| M6 | Optionals | `optionals` passes (optional types, `.?`, `[?`, `optional.of/none/ofNonZeroValue`, `orValue`, `optMap`, `optFlatMap`) |
| M7 | CEL Policy + CELTest | cel-go `policy/testdata` passes, including the conformance runner cases; `tests.yaml` files run identically under `celtest` and `cel-swift policy test` |
| M8 | 0.x release for PRBar | DocC for core + policy, API review, tagged release; PRBar depends on it |
| M9 | Regex | `CELRegex` passes Go's RE2 test data; `matches` and regex-based ext functions enabled |
| M10 | Extensions | `string_ext`, `math_ext`, `lists_ext`, `bindings_ext`, `block_ext`, `encoders_ext`, `network_ext`, sets, two-variable comprehensions, formatting pass |
| M11 | Protobuf | `protoc-gen-cel-swift`, WKTs, `proto2`, `proto3`, `proto2_ext`, `enums` (minus strong enums), `wrappers`, `dynamic`, remaining `comparisons` / `parse` / `fields` pass |
| M12 | **cpp parity** and 1.0 | skip list no longer than cel-cpp's with reasons; differential suite green nightly for two weeks; API frozen; Swift Package Index listing |

Rough effort with agent-heavy porting and human review as the bottleneck: M0 to M8 several weeks; M9 to M12
as long again, with protobuf (M11) the largest single item.

## Working method

The repo's `CLAUDE.md` sets the porting rules, so any agent session follows the same loop:

- **Port, don't invent.** Each Swift file names its cel-go source file(s) in a header comment; behaviour
  follows cel-go unless the spec says otherwise, and any deliberate divergence is listed in
  `docs/divergences.md` with the reason.
- **The grind loop**: run the conformance target for one file, group failures by cause, read the matching
  cel-go code, fix, rerun; then run the differential suite before committing. A milestone is done when its
  exit criteria hold, not when most tests pass.
- **Skip list discipline**: adding an entry needs a reason and an issue; removing entries is the goal of
  every milestone.
- **Small PRs per feature area** once the repo is public, each with the dashboard delta in the description.
  Until then, commits go straight to `main` with the dashboard delta in the commit message.
- Swift conventions: strict concurrency, `Sendable` everywhere, value types, no force unwraps outside tests,
  no `Foundation` in hot paths, `golines`-style formatting via `swift-format` config in the repo.

## Licensing

Apache-2.0, matching cel-go and cel-spec. A port of cel-go is a derivative work: keep cel-go's copyright
notices in a `NOTICE` file and in ported file headers. cel-spec test data comes in as a git submodule, not a
copy. Go's `regexp` is BSD-3-Clause; its notice goes into `NOTICE` and the `CELRegex` file headers.

## Risks

- **Protobuf without dynamic messages**: codegen is a real subsystem (plugin, runtime adapters, registry).
  It is isolated in `CELProtobuf` and comes last, so it can't block the core or PRBar.
- **Number formatting**: `string(double)` and double parsing edge cases (`conversions/string/double_hard` is
  skipped even by cel-cpp on older compilers). Dedicated formatter, differential tests.
- **Unicode**: CEL counts code points; any accidental use of `String.count` or `Character` APIs is a bug.
  A lint check for those APIs in `Sources/CEL`.
- **Time zones on Linux**: tzdata must be present; legacy `US/...` zones vary by system (also skipped by
  cel-cpp).
- **Performance of an enum-of-existentials value model**: measure early in M2 with the benchmark set;
  switch hot paths to specialised nodes if needed.
- **Compile times**: very large `switch` statements over overloads slow Swift builds; keep the standard
  library split across files and use dispatch tables.
- **Spec drift**: pin cel-spec and cel-go versions; bump deliberately, with the dashboard diff in the PR.
- **Security**: rules come from other people's repositories, so a cost-accounting bug is a denial-of-service
  bug. Fuzzing and differential cost checks are part of CI, not a later hardening step.

## PRBar integration

- `.package(url: "https://github.com/lustefaniak/cel-swift", from: "0.1.0")`, using `CEL` and `CELPolicy`.
- PRBar declares its per-stage fact schemas as CEL environment configs, compiles one policy per stage, uses
  partial evaluation for lazy AI signals, state tracking for the explain view, and the cost limit plus a
  deadline as the termination guarantee.
- Until the library covers a feature (regex before M9, extensions before M10), PRBar's loader rejects it
  with a clear error rather than evaluating something different.
- Design context: `prbar/docs/design/review-rules.md`.

## Open questions

- Name: `cel-swift` or `swift-cel` (Swift package convention). Decide before the first tag; renaming after
  publishing breaks every `Package.swift` that depends on it.
- Public from the first commit, or private until M3? No customer data is involved, so public from day one
  costs nothing and invites early contributors.
- Swift macro (`@CELType`) for exposing native Swift structs as CEL objects, analogous to cel-go's
  `ext.NativeTypes`: useful for PRBar's facts, needs a `swift-syntax` dependency, so it would live in its own
  target.
- Minimum Swift version: 6.0 is enough for everything planned; nothing here needs 6.2.

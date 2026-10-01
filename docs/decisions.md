# Decisions before 0.1.0

What the maintainer decided on the public API and behaviour questions that had to be settled before the
first tag (2026-10-01). Each entry gives the outcome and the reason in short; the options considered are in
the git history of this file (up to `b01d58c`). After `0.1.0` changing any of these is a SemVer-visible
break (allowed in a minor before 1.0).

**Swift ergonomics go in a separate module.** After the port, a module on top of the core (name open,
`CELSwift` or `CELErgonomics`) adds the idiomatic layer: `Codable` activations and result decoding, result
builders or macros for declarations and custom functions, typed function bindings through generics and
parameter packs, `ExpressibleBy*Literal` conformances, async evaluation, macro- or property-wrapper-driven
environments. The core `CEL` module stays close to cel-go's shape (port fidelity). Being in the same package,
the new module can use the core's `package` declarations.

| # | Question | Decision | State |
|---|---|---|---|
| 1 | Package name | keep `cel-swift` | done |
| 2 | Public `enum CEL` clashing with the module | delete it | done |
| 3 | Public AST | keep it `package` for 0.1 | done |
| 4 | Proto conversion of checked expressions | not in 0.1 | done |
| 5 | `Value` accessor naming | keep `asInt` and siblings | done |
| 6 | Boxed list, map, object and error payloads | `indirect` cases, public shape unchanged | done |
| 7 | Strong enums | no new `Value` / `CELType` cases, opaque object value behind an option | done |
| 8 | Spec-over-cel-go defaults | keep the spec behaviour, no options | done |
| 9 | Shared ANTLR prediction cache | shared cache with antlr-go's finer locking | decided: implementing |
| 10 | Public names that abbreviate or clash | full words, no clash with dependencies | done |

## 1. Package name: keep `cel-swift`

The CEL family names its implementations `cel-<lang>` (cel-go, cel-cpp, cel-rust, cel-java), which is how
people search for them, and the GitHub URL is what clients type. The `swift-<name>` convention is not
enforced anywhere. Module and product names (`CEL`, `CELPolicy`, ...) are unaffected.

## 2. The public `enum CEL`: deleted

A type named like its module shadows the module in qualified names: `CEL.Environment`, written to
disambiguate against another library's `Environment`, was looked up in the enum and failed, and Swift 6.0
has no way around it. The enum held only `specVersion`; the pinned cel-spec version is recorded in
`CHANGELOG.md` for each release and in the `third_party/cel-spec` submodule.

## 3. Public AST: `package` for 0.1

`Expr`, `AST`, `SourceInfo`, `NavigableExpr`, `ReferenceInfo` and `OptimizerContext` stay `package`. Nothing
PRBar needs is blocked, and the AST stays free to change while the parser and checker may still be reshaped
for performance. Clients get `ExpressionValidator` closures over the checked expression and the built-in
optimizers. The ergonomics module can use the `package` AST, so a public facade is needed only for clients
outside the package (custom parser macros, their own optimizers or interpreter decorators); when it comes,
before 1.0, it follows the shape of cel-go's `ast` package. The cel-go tests it would unblock are listed in
the headers of `Tests/CELTests/APICelTests.swift`, `APIConstantFoldingTests.swift` and
`APIInliningTests.swift`.

## 4. Converting expressions to and from the cel-spec protos: not in 0.1

Clients keep the source text and recompile (parse plus check is milliseconds). When needed, the conversion
goes into `CELProtobuf` behind the public `CheckedExpression` (`CheckedExpression(proto:)`,
`.checkedExprProto`), independent of the public AST question. Skipped meanwhile: `TestAstIsChecked` and the
exprpb half of `TestParseWithMacroTracking`.

## 5. `Value` accessors: keep `asInt`

`asBool`, `asInt`, ..., `asUnknown` return optionals and match one case; the `as` prefix says it is a case
match that may fail, not a numeric conversion (`intValue` in the Foundation and swift-protobuf sense
converts, and `.int(5).doubleValue == nil` would surprise). Conversions such as `Int(value)` or `Decodable`
results belong to the ergonomics module.

## 6. `Value` payloads: `indirect` list, map, object and error cases

`.list`, `.map`, `.object` and `.error` are `indirect`, so Swift stores their payloads in a heap box. `Value`
drops from 41 to 17 bytes and stops going through the outlined value witness on every copy; evaluation got
1.4 to 2 times faster (numbers in `docs/performance.md`). The case list, `ListValue` / `MapValue` /
`ObjectValue`, `ArrayList` and `OrderedMap` are unchanged, so the change is source compatible and needs no
API decision. Replacing the existentials with concrete final classes was rejected: it would change the
public collection API and remove the extension point for host adapters (lazy lists over client data).

## 7. Strong enums: no new cases (done)

Enum values are modelled as an object value with an opaque enum type, behind an environment option that is
off by default (the `legacy_*` conformance sections must keep passing), the way `CELExtensions` models
`net.IP` / `net.CIDR`. `Value` and `CELType` are public enums clients switch over; adding cases for a
feature most clients never enable would break every exhaustive switch after 0.1. Their case lists stay the
ones the spec closes today.

Implemented as `Environment.Option.strongEnums` and the `EnumValue` object value (type
`.opaque(name: "pkg.Enum", parameters: [])`); `CELProtobuf` reads and writes enum fields as enum values when
its types have strong enums, which the option switches on for the environment's types.

## 8. Spec-over-cel-go defaults: keep the spec behaviour

`indexOf` / `lastIndexOf` with an offset past the end raise `index out of range`, and `ip()` accepts the
hexadecimal IPv4-mapped IPv6 form, as cel-spec and cel-cpp do (cel-go differs on both, see
`docs/divergences.md` § Extensions). No options in 0.1: the conformance suite is the gate, the inputs are
rare, and library options are additive, so a cel-go-compatible flag can come when a client asks. For
`indexOf`, follow cel-spec when its pinned version changes.

## 9. Shared ANTLR prediction cache (decided: implementing)

antlr4-go keeps the prediction DFAs in a process-wide cache, cel-swift rebuilt them for every parse, which
made parsing about 8 times slower than cel-go. The cache is shared, with antlr-go's finer locking (lock only
DFA state lookup and insertion and edge updates, compute target states outside the lock) so concurrent
parses scale; owned by the parser per `Environment` if process-wide state is a problem. The coarse-lock
prototype (`perf/shared-parser-cache`) serialized concurrent parses.

## 10. Public names: full words, no clashes with dependencies

Renames are free before 0.1, so the public surface follows the Swift API design guidelines: words spelled
out where cel-go abbreviates (`expressionID`, `argumentTypes`, `typeParameters`, `libraryNames`), with the
cel-go name kept in the documentation; `StructFieldType` instead of `FieldType`, which clashed with
SwiftProtobuf's; `CELTimestamp(secondsSinceEpoch:nanoseconds:)` takes the nanoseconds as `Int32` in
`0..<1_000_000_000` (a precondition) so nothing is truncated or wrapped silently; `TestResult.Outcome` is a
struct with static members so outcomes can be added without breaking clients. The full list is in
`CHANGELOG.md` § 0.1.0. Type names that are the port's vocabulary (`VariableDecl`, `FunctionDecl`,
`OverloadDecl`, `CELType.typeParam`) stay.

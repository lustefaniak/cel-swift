# Decisions before 0.1.0

What the maintainer decided on the public API and behaviour questions that had to be settled before the
first tag (2026-10-01). Each entry gives the outcome and the reason in short; the options considered are in
the git history of this file (up to `b01d58c`). After `0.1.0` changing any of these is a SemVer-visible
break (allowed in a minor before 1.0).

**Swift ergonomics go in a separate module.** After the port, a module on top of the core (`CELSwift`, see
`docs/ergonomics.md` for the name, the design and what is left) adds the idiomatic layer: `Codable` activations and result decoding, result
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
| 9 | Shared ANTLR prediction cache | shared cache with antlr-go's finer locking, owned per `Environment` | done |
| 10 | Public names that abbreviate or clash | full words, no clash with dependencies | done |
| 11 | `OverloadDecl.Option.lateBinding` without a runtime half | `package` until a supply path exists | done |
| 12 | Untyped `throws` on closed error sets | typed throws on declarations, containers, registry and protobuf conversion | done |
| 13 | `MapValue.keys: [MapKey]` as the iteration requirement | `forEachKey(_:)` is the requirement, `keys` an extension | done |
| 14 | Provider protocols without defaults | `TypeProvider` requirements default to misses | done |

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

## 9. Shared ANTLR prediction cache (done)

antlr4-go keeps the prediction DFAs in a process-wide cache, cel-swift rebuilt them for every parse, which
made parsing about 8 times slower than cel-go. The cache is now shared, with antlr-go's finer locking: two
read-write locks, one for DFA state lookup and insertion, one for edge reads and updates, and target states
computed outside both, so concurrent parses scale (numbers in `docs/performance.md`). The coarse-lock
prototype (`perf/shared-parser-cache`) serialized concurrent parses. The locks are pthread read-write locks
in an `@unchecked Sendable` class whose invariants are documented on it; plain mutexes scaled worse, and
`Synchronization` is above the macOS 13 floor.

The cache is owned by the `Parser`, so by the `Environment`, not process-wide: copies of an environment and
environments made with `extending` share it, and it is freed with the last of them. Measurements gave no
reason for global state: only a new environment's first parses pay for building the DFA paths they take,
and hosts keep an environment for many expressions. Owned caches also keep growth bounded by the lifetime of the
environments that fed them (the DFAs grow with the variety of inputs and are never trimmed, as in cel-go),
and keep tests and fuzz targets independent of each other.

## 10. Public names: full words, no clashes with dependencies

Renames are free before 0.1, so the public surface follows the Swift API design guidelines: words spelled
out where cel-go abbreviates (`expressionID`, `argumentTypes`, `typeParameters`, `libraryNames`), with the
cel-go name kept in the documentation; `StructFieldType` instead of `FieldType`, which clashed with
SwiftProtobuf's; `CELTimestamp(secondsSinceEpoch:nanoseconds:)` takes the nanoseconds as `Int32` in
`0..<1_000_000_000` (a precondition) so nothing is truncated or wrapped silently; `TestResult.Outcome` is a
struct with static members so outcomes can be added without breaking clients. The full list is in
`CHANGELOG.md` § 0.1.0. Type names that are the port's vocabulary (`VariableDecl`, `FunctionDecl`,
`OverloadDecl`, `CELType.typeParam`) stay.

## 11. Late binding: `package` for 0.1

`OverloadDecl.Option.lateBinding` (cel-go `LateFunctionBinding`) declares an overload whose implementation
is supplied at evaluation time; the declaration validation and constant folding honour it. cel-go v0.32
supplies such implementations only through the deprecated `cel.Functions` program option, and
`Program.Option` has no counterpart, so the public marker promised a runtime half that did not exist and
would have constrained its shape. The option and `hasLateBinding` on `OverloadDecl` and `FunctionDecl` are
`package`; the ported cel-go tests keep using them. Making them public again, together with a program option
that supplies bindings by overload id, is additive.

## 12. Typed throws on closed error sets

`Container`, `FunctionDecl`, `OverloadDecl` and `TypeRegistry` only ever throw `DeclarationError`, and
`ProtobufTypes.message(from:as:)` only `EvalError`, so their public operations and option closures use
`throws(DeclarationError)` and `throws(EvalError)`, like `Environment`, `compile` and `evaluate` already did.
Callers composing the lower-level API keep the concrete error, and changing the thrown type after 0.1
would break stored function types. With this every public throwing operation of the libraries has a
concrete error type; plain `throws` is left only on `package` hooks whose closures run code from other
targets (environment options, program decorators), which `Environment` maps to `DeclarationError`. On Swift 6.0 a closure only
gets a typed throw when it says so (`{ (c: inout Container) throws(DeclarationError) in ... }`) and a
`do` block only with `do throws(DeclarationError)`; both are written out.

## 13. `MapValue` iterates keys with `forEachKey(_:)`

The protocol required `keys: [MapKey]`, so every adapter over host data had to build an array of all keys
for each iteration, which defeats the lazy adapters `Value` advertises. The requirement is now
`forEachKey(_ body: (MapKey) throws -> Bool) rethrows`: the map calls `body` with each key in its
iteration order until `body` returns `false`, so `exists` and equality stop early. The order must be the
same on every call (comprehensions, equality and formatting depend on it) but need not be sorted.
`keys` stays as an extension that collects the keys, and `OrderedMap` keeps its stored `keys`. An
associated `Sequence` type was rejected: it makes clients name an iterator type and iterates through an
existential iterator for `any MapValue`. Typed throws (`throws(Failure)` generic over the closure's error)
was the first choice, but Swift 6.0 cannot see a method's generic parameter in the thrown type of a
protocol requirement ("cannot find type 'Failure' in scope"), so the requirement uses `rethrows`; it can
move to typed throws when the floor is raised. The benchmark expressions, with a new
`comprehension-over-map` case, are unchanged within noise (`tools/bench/bench.py`, eval phase, 0.99 to
1.02 times).

## 14. `TypeProvider` defaults

A provider composed under a `TypeRegistry` (`Environment.Option.typeProvider`) usually answers one kind
of lookup, such as identifiers or a few struct types, but had to implement all six requirements. Each
now has a default in a protocol extension that reports the miss `TypeRegistry` itself reports: `nil` for
the lookups, `unknown enum name 'x'` from `enumValue` and `unknown type 'x'` from `newValue`. This is
additive, and it gives requirements added later a place for a default, so adding one does not break
conformers. `ObjectValue` and `PolicyTagVisitor` already had defaults; `StructTypeDescriptor` has none
because every requirement describes the type, and `TypeAdapter` has a single requirement.

## 15. Interpreter nodes share an `@unchecked Sendable` base class

`Interpretable` was constrained to `AnyObject`. On Darwin a class existential may hold an Objective-C object,
so every call through `any Interpretable` asked the runtime for the object's type (`swift_getObjectType`) and
every copy used `swift_unknownObjectRetain` / `Release`; with qualifiers stored as 40-byte opaque existentials,
these were about a sixth of evaluation. `Interpretable`, `Qualifier` and `Attribute` are now constrained to
`package class InterpretableNode`, an empty class every node inherits, so the compiler knows the nodes are
native Swift objects (evaluation 0.51–0.88× with the other changes of that pull request, `docs/performance.md`).

The base class is `@unchecked Sendable` and the nodes inherit the conformance, so the compiler no longer
checks each node's stored properties for sendability. That is accepted because the nodes are immutable by
construction: final classes whose stored properties are `let`s of `Sendable` types, built once when a program
is planned and only read afterwards. A node with mutable state would break that invariant silently, so new
nodes keep to `let` properties; state that changes during evaluation lives in the `ExecutionFrame`, which is
created per evaluation. `package` classes cannot be subclassed from other modules, so nodes defined outside
`CEL` (the `cel.block` nodes in `CELExtensions`) are `ClosureInterpretable` instances.

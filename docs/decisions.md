# Open decisions before the first tag

Questions only the maintainer can settle, each with the options, what they cost, the code they touch
and a recommendation. Every one of them changes public API or behaviour, so all should be settled
before `0.1.0`: after the tag a change is a SemVer-visible break (allowed in a minor before 1.0, but
PRBar pays for it). When one is decided, record the outcome here in a line and move the details into
`docs/architecture.md` or `docs/divergences.md`.

## 1. Package name: `cel-swift` or `swift-cel`

Swift packages are conventionally `swift-<name>` (`swift-protobuf`, `swift-collections`); the repo is
`cel-swift`. The package name appears in every client's `.product(name: "CEL", package: "cel-swift")`,
so renaming after the first tag breaks every dependent `Package.swift`.

- **Keep `cel-swift`**: no work; matches cel-go / cel-cpp / cel-rust / cel-java naming, which is how
  people search for CEL implementations.
- **Rename to `swift-cel`**: follows the Swift ecosystem convention (Swift Package Index, swiftlang
  packages). Costs a GitHub repo rename (redirects keep old URLs working), `Package.swift` `name:`,
  README, plan, `NOTICE`, the `cel-swift` CLI name if it follows (probably not).

Affects: `Package.swift` (`name:`), README install snippet, `docs/plan.md`, CI badge links later.
Module and product names (`CEL`, `CELPolicy`, ...) do not change either way.

Recommendation: **keep `cel-swift`**. The CEL family names its implementations `cel-<lang>`, the
GitHub URL is what clients type, and the convention is not enforced anywhere. Decide now either way.

## 2. The public `enum CEL` shares the module's name

`Sources/CEL/CEL.swift` declares `public enum CEL { static let specVersion }`. A type named like its
module shadows the module in qualified names: a client that writes `CEL.Environment` to disambiguate
(for example against another library's `Environment`) gets a lookup in the enum, which fails. Only
`Tests/CELTests/CELTests.swift` uses it.

- **Delete the enum** and expose the spec version, if wanted at all, as `Environment.specVersion` or
  a free `let celSpecVersion`. Clean qualification, one test changes.
- **Rename it** (`CELInfo`, `CELVersion`): keeps the constant, adds a type with one member.
- **Keep it**: qualification stays broken for clients, and the 6.0 floor has no language-side way
  around a type that shadows its module.

Recommendation: **delete it** and drop the constant (the pinned cel-spec version is in the changelog
and the submodule). Small change, no maintainer cost after.

## 3. Public AST

`Expr`, `AST`, `SourceInfo`, `NavigableExpr`, `ReferenceInfo` and the optimizer context are `package`
(about 120 declarations in `Sources/CEL/AST`, plus `OptimizerContext` in `API/Optimizer.swift`).
Without them clients cannot write custom macros, custom validators that inspect the tree, custom
`ASTOptimizer`s (including `OptimizeWithSource`), interpreter decorators, or their own AST tooling.
The cel-go tests skipped for this reason are listed in the headers of `Tests/CELTests/APICelTests.swift`
and `APIConstantFoldingTests.swift` / `APIInliningTests.swift` (TestCustomMacro, TestMacroInterop,
TestCustomInterpreterDecorator*, custom optimizer rows).

- **Keep it `package` for 0.1**: nothing PRBar needs is blocked; the AST stays free to change (the
  parser and checker work is cel-go-shaped and may still be reshaped for performance). Clients get
  only `ExpressionValidator` closures over the checked expression and the built-in optimizers.
- **Make the current types public**: `Expr` is already a value type with an `Expr.Kind` enum, so it is
  Swift-shaped; but `Expr.Kind` becomes a public enum clients switch over (adding a case later is
  breaking), and every helper (`renumberIDs`, `transformPostOrder`, navigation) becomes a commitment.
  Needs DocC on ~120 declarations, and decisions on mutability of `SourceInfo` and macro call maps.
- **A narrow public facade**: read-only `public struct ExpressionNode` views (kind, id, children,
  type, location) plus a macro API in the shape of cel-go's `MacroExprFactory`; internals stay
  `package`. More design work, smaller commitment.

Recommendation: **keep it `package` for 0.1**, design the facade before 1.0 when a client needs custom
macros. Record the cel-go tests it unblocks in the facade's issue.

## 4. Converting expressions to and from the cel-spec protos

cel-go converts `Ast` to and from `cel.expr.ParsedExpr` / `CheckedExpr` (`cel.AstToCheckedExpr` and
friends), which is how checked expressions are cached, shipped between services, and how conformance
`check_only` / `typed_result` comparisons work. Here the generated protos live in `CELSpecProtos`, a
non-product target the conformance tests use; the conversion code in the tests is not public.

- **No conversion in 0.1**: clients keep the source text and recompile (parsing plus checking is
  milliseconds). Skipped tests: TestAstIsChecked, the exprpb half of TestParseWithMacroTracking.
- **A `CELProtobuf` API** (`CheckedExpression(proto:)`, `.checkedExprProto`): the dependency on
  swift-protobuf is already there; `CELSpecProtos` would become a product (or its generated types
  move into `CELProtobuf` with `package` visibility and only the conversion is public). Depends on
  decision 3 only loosely: the conversion can stay behind the public `CheckedExpression`.
- **Text or JSON serialisation of the checked AST** without protobuf: invented format, not
  interoperable with cel-go. Not recommended.

Recommendation: **not in 0.1**; when needed, add it to `CELProtobuf` behind `CheckedExpression`, so the
AST question stays separate.

## 5. `Value` accessor naming: `asInt` or `intValue`

`Sources/CEL/API/Value+Native.swift` has `asBool`, `asInt`, `asUInt`, `asDouble`, `asString`,
`asBytes`, `asList`, `asMap`, `asDuration`, `asTimestamp`, `asType`, `asObject`, `asError`,
`asUnknown` (all `Optional`). Used by the DocC articles and a handful of tests and sources, so a
rename is cheap now.

- **Keep `asInt`**: reads as a conversion attempt that may fail, which matches the optional result;
  short; consistent with the package-internal `asCall` / `asIdent` on `Expr`.
- **`intValue`**: the Foundation / `NSNumber` and swift-protobuf style (`value.intValue`), but there
  it is non-optional and converting, while here `.int(5).doubleValue` would be `nil`, which surprises.
- **Both**: no.

Recommendation: **keep `asInt`** and its siblings; the name tells the reader it is a case match, not a
numeric conversion. If clients ask for conversions, add `Int(_ value: Value)`-style initializers.

## 6. Class-backed list, map and object payloads in `Value`

`Value.list(any ListValue)`, `.map(any MapValue)` and `.object(any ObjectValue)` hold existentials; the
concrete `ArrayList` / `OrderedMap` are structs. Benchmarks (`swift run -c release CELBenchmarks`,
`tools/bench`) put cel-swift at 2 to 3 times cel-go, and profiles show `Value` copies (existential
boxes, retain/release of the struct storage) dominating comprehension-heavy expressions.

- **Keep the existential protocols, optimise inside**: make `ArrayList` / `OrderedMap` wrap one final
  class so a copy is one retain, without changing the public shape. Not breaking.
- **Change the cases to concrete final classes** (`.list(CELList)`, `.map(CELMap)`): fastest dispatch
  and smallest `Value`, but host adapters (lazy lists over client data) need a different extension
  point, and the case payload types are public: breaking, so before 0.1 or never.
- **Leave it**: performance is acceptable for policy-sized expressions (PRBar's use).

Recommendation: **keep the public cases as they are** and do the first option (class storage inside
the concrete types) as a performance task; it needs no API decision. Revisit only if profiles after
that still point at the existential dispatch.

Measured (`docs/performance.md`): the profiles point at the size of `Value` more than at the structs'
storage. A 40-byte existential payload makes `Value` 41 bytes, and every copy or destroy of any `Value`
runs the outlined value witness (20 to 30% of eval profiles). Branch `perf/class-payloads` keeps the
public cases and types and only marks `.list`, `.map`, `.object` and `.error` `indirect` (Swift boxes
those payloads): `Value` drops to 17 bytes, eval gets 1.4 to 2 times faster (policy 58 to 29 µs,
comprehension-nested 3.1 to 1.6 ms), from 2.5 to 5.5 times cel-go down to 1.7 to 3. Source compatible,
one more allocation per constructed list/map/object/error; full suite and conformance pass.

## 7. Strong enums: enum values and types in `Value` and `CELType`

The only conformance tests left (35 checked, 29 parse-only) are the `enums/strong_proto2` and
`strong_proto3` sections; cel-go and cel-cpp skip them too, and `docs/status.md` § Next sizes the work
at about one session after this decision. Strong enums make `TestAllTypes.NestedEnum.BAR` a value of
type `TestAllTypes.NestedEnum` instead of `int`, with `E(int)` / `E(string)` conversions (int32 range
and name checks), `int(e)`, `type(e) == E`, equality only within the enum, and proto enum fields read
and written as enum values. The `legacy_*` sections must keep passing, so it is an environment option
off by default.

- **New public cases** (`Value.enumValue(typeName:number:)`, `CELType.enum(String)`): explicit and fast
  to match, but `Value` and `CELType` are public enums clients switch over, so adding cases is breaking
  after 0.1 and forces every exhaustive switch to handle a feature most clients never enable.
- **No new cases**: an `EnumValue` struct conforming to `ObjectValue` (the way `CELExtensions` models
  `net.IP` / `net.CIDR` values with `CELType.opaque(name:parameters:)`), and the enum type as
  `.opaque(name: "pkg.Enum", parameters: [])` or `.object(name)` with a type-provider flag. Keeps the
  closed case lists; costs a little dispatch in equality and conversion paths.
- **Decide later**: adding the cases before 0.1 "just in case" is cheap now and breaking later, so if
  option 1 is preferred it should land before the tag even without the implementation.

Affects: `Sources/CEL/Values/Value.swift`, `Sources/CEL/Types/CELType.swift`, the checker's identifier
resolution for enum type names, the conversion functions in `Stdlib`, `CELProtobuf` field getters and
setters, and the conformance runner's `enum_value` conversion.

Recommendation: **no new cases**: model enum values as an object value with an opaque type, behind an
environment option, as the network extension already does for IPs. The case lists of `Value` and
`CELType` stay the ones the spec closes today.

## 8. Spec-over-cel-go defaults that may want an option

Two behaviours follow the cel-spec suite and cel-cpp instead of cel-go (both in `docs/divergences.md`
§ Extensions). A client porting rules from a cel-go deployment would see different results.

- **`indexOf` / `lastIndexOf` with an offset past the end** raise `index out of range` here; cel-go
  returns -1 since v0.22 and skips those spec tests, expecting the spec to change.
- **`ip('::ffff:c0a8:1')`** (hexadecimal IPv4-mapped IPv6) is accepted here as the IPv4 address it maps;
  cel-go rejects it for Kubernetes compatibility.

Options for each:

- **Keep the spec behaviour, no option**: one behaviour, matches the conformance suite; cel-go users
  see a difference on inputs that are rare (an out-of-range offset is a bug in the rule; the hex
  mapped form is unusual).
- **A library option** (for example a cel-go-compatible `indexOf` flag on `Library.strings` and a
  strict IP parsing flag on `Library.network`): exact cel-go parity on request; two code paths each
  and test rows for both. Options are additive, so they can come later without breaking.
- **Switch the default to cel-go** with a spec option: contradicts the conformance suite we gate on.

Recommendation: **keep the spec behaviour without options for 0.1**. Options are additive and can be
added when a client asks; for `indexOf`, follow cel-spec when its pinned version changes (the
divergence entry already says so).

## 9. Sharing the ANTLR prediction cache across parses

antlr4-go keeps the parser's prediction DFAs in a process-wide static, so cel-go builds them once per
process; cel-swift rebuilds them for every parse, which makes parsing about 8 times slower than cel-go
(`docs/performance.md`) and 100+ ms for long inputs. Sharing them is global mutable state, which CLAUDE.md
asks to raise first; without `Synchronization` (macOS 15) it needs an `@unchecked Sendable` class with a
pthread mutex.

- **Share behind one lock** (branch `perf/shared-parser-cache`, `PredictionCache.shared`): single-threaded
  parse 3 to 5 times faster, to 2 to 3 times cel-go. The lock covers all of `adaptivePredict`, so concurrent
  parses serialize (8 threads parsed more slowly together than one thread alone).
- **Share with antlr-go's finer locking** (lock only DFA state lookup/insert and edge updates, compute target
  states outside): same single-thread gain, scales with threads; more code to port and test.
- **Per-`Environment` cache**: no process-wide state, warm after the first parses of an environment; still
  needs the lock, since environments are `Sendable` and shared between tasks.
- **Leave it**: parse is usually done once per expression and cached by the host.

Recommendation: the finer-locked shared cache, owned by the parser (per `Environment`) if global state is
the sticking point.

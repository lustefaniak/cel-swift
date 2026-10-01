# cel-swift architecture

How the pieces of `Sources/CEL` fit together, for whoever builds on them next. `docs/plan.md` has the
milestones; `docs/divergences.md` lists every deliberate difference from cel-go.

## Values and types (`Sources/CEL/Values`, `Sources/CEL/Types`)

Ported from cel-go `common/types`. Where cel-go has one Go type per CEL value implementing `ref.Val` and
trait interfaces, Swift has one enum and plain methods.

### `Value` (public enum, closed case list)

```swift
public enum Value: Sendable {
  case null, bool(Bool), int(Int64), uint(UInt64), double(Double), string(String), bytes([UInt8])
  case list(any ListValue), map(any MapValue), type(CELType)
  case duration(CELDuration), timestamp(CELTimestamp)
  indirect case optional(Value?)          // optional.of(x) / optional.none()
  case object(any ObjectValue)            // messages, native Swift types, abstract values
  case error(EvalError), unknown(UnknownSet)
}
```

- The case list is closed by the spec (CLAUDE.md "public enums clients switch over"). Anything new, such as
  an extension's abstract type (`net.IP`), is an `ObjectValue` with an `.opaque(name:parameters:)` type.
- `==` on `Value` is **structural** (`1 != 1u`, NaN != NaN, strings by Unicode scalars). CEL equality is
  `celEquals(_:)` (package), the port of `types.Equal`: heterogeneous numeric equality, `null` only equals
  `null`, errors/unknowns return themselves.
- Strings: every operation works on `utf8` / `unicodeScalars`. Swift's `String ==`, `<`, `hasPrefix` and
  `contains` use canonical equivalence and are wrong for CEL; never use them on CEL strings
  (`compareUTF8`, `stringContains`, `MapKey` hashing show the pattern).
- `description` is cel-go's `types.Format` (`1u`, `2.0`, `b"\150"`, `{"a": 1}` with sorted keys,
  `duration("1.5s")`, `timestamp("...Z")`). Literal conformances (`3`, `"x"`, `[1, 2]`, `["k": 1]`) exist
  for tests and host code.
- `EvalError(message, expressionID:)` is the error payload. Messages are cel-go's verbatim (`division by zero`,
  `no such overload`, `no such key: x`, `index '5' out of range in list size '1'`, ...). Package statics:
  `Value.noSuchOverload`, `EvalError.intOverflow`, ...; helpers `Value.valOrError`,
  `Value.maybeNoSuchOverload`, `labellingError(with:)` (= `LabelErrNode`).
- `UnknownSet` / `AttributeTrail` / `AttributeQualifier` port `types.Unknown`; `merging(_:)`,
  `contains(_:)`, `Value.maybeMergeUnknowns`.

### Operations (package API on `Value`)

Ports of the trait methods, all returning `Value` (errors as `.error`, never thrown):
`add`, `subtract`, `multiply`, `divide`, `modulo`, `negate`, `compare` (`.int(-1/0/1)` or error),
`celEquals`, `size`, `contains` (the `in` container side), `get` (index list/map, field of object),
`convert(to: CELType)` (the conversion functions and `type()`), `match` (regex, via `CELRegex`),
`receive(function:overload:args:)` (cel-go `Receive`: string/duration/timestamp methods).
Overflow-checked arithmetic is `Values/Overflow.swift` (`overflow.go`).

Go formatting/parsing that conversions rely on is ported and pinned by fixtures generated from cel-go
(`tools/value-fixtures`, `Tests/CELTests/Fixtures`): `string(double)` = Go `FormatFloat(f, 'g', -1, 64)`,
`double(string)` = `ParseFloat`, `int/uint(string)`, `bool(string)`, `duration(string)` =
`time.ParseDuration`, `string(duration)`, RFC 3339 parse / `RFC3339Nano` format.

### Collections

- `protocol ListValue { var count: Int; func element(at:) -> Value }` and
  `protocol MapValue { var count: Int; var keys: [MapKey]; func value(forKey: MapKey) -> Value? }`.
  Host data adapts lazily by conforming; `ArrayList` (`[Value]`) and `OrderedMap` (insertion ordered) are
  the concrete types for literals and results. Fast paths: `list as? ArrayList`.
- `MapKey` is `bool | int | uint | string`. Cross-numeric lookup (`m[1.0]` finds `1` or `1u`) is
  `MapValue.find(_ key: Value)` built on exact `value(forKey:)`, the port of `refValMapAccessor.Find`.
- List `+` materializes a new `ArrayList` (cel-go builds a view). Comprehension accumulators in the
  interpreter should append to a local `[Value]` (cel-go's `NewMutableList`) instead of `+` per step.

### `CELType` (public indirect enum, closed case list)

`dyn, any, bool, bytes, double, duration, error, int, list(T), map(key:value:), null, opaque(name:parameters:),
string, object(name), timestamp, type(T?), typeParam(name), uint, unknown, wrapper(T)`.

- `kind` mirrors cel-go `Kind` (a wrapper has its wrapped kind), so checker code ports switch-for-switch.
- `runtimeTypeName` (`list`, `google.protobuf.Duration`, message name), `parameters`, `declaredTypeName`
  (`wrapper(int)`), `description` (cel-go `String()`: `map(string, list(int))`, `<T>`).
- Relations: `isExactType`, `isEquivalentType` (ignores type param names), `isAssignable(from:)`
  (type-check), `isAssignableRuntime(_ value:)` (runtime guard, inspects first element of lists/maps).
- `CELType.objectType(name)` maps well-known protobuf names (`google.protobuf.Int64Value` -> `wrapper(int)`,
  `Struct` -> `map(string, dyn)`, `Value` -> `dyn`, ...). `CELType.optional(T)` is `opaque("optional_type", [T])`.
- `TypeTraits` (OptionSet, cel-go `traits` bit layout). `CELType.traits` gives the builtin traits;
  `Value.traits` asks the `ObjectValue` for objects.
- A runtime type value `.type(t)` equals another by `runtimeTypeName` (`type([1]) == type(["a"])`).

### Objects and the type provider

- `protocol ObjectValue: Sendable { var celType; var traits; func field(_:) -> Value;
  func isFieldSet(_:) -> Value; func isEqual(to:) -> Bool; var isZeroValue }`: how protobuf messages
  (`CELProtobuf`) and native Swift types appear. Unknown fields return `no such field 'x'`.
- `protocol StructTypeDescriptor { typeName; fieldNames; fieldType(named:) -> StructFieldType?;
  newValue(fields:) -> Value }`: describes a message type to the checker and to `Msg{f: v}` construction.
- `StructFieldType { type: CELType; isSet; getFrom; isJSONField }`.
- `protocol TypeProvider` (cel-go `types.Provider`): `enumValue`, `findIdent`, `findStructType`
  (returns `type(T)`), `findStructFieldNames`, `findStructFieldType`, `newValue`.
  `protocol TypeAdapter { nativeToValue(Any) -> Value }`.
- `struct TypeRegistry: TypeProvider, TypeAdapter` (value type; copies are independent): standard type
  identifiers pre-registered, `register(_ type:)`, `register(_ descriptor:)`, `registerEnumValue(_:number:)`,
  `init(composing:adapter:)` for a fallback provider (cel-go `ComposeTypes`). `nativeToValue` converts Swift
  scalars, `[UInt8]`, `CELDuration`, `CELTimestamp`, `ListValue`/`MapValue`/`ObjectValue` conformances and
  (eagerly) arrays and dictionaries.

## Declarations and bindings (`Sources/CEL/Decls`)

Ported from cel-go `common/decls` and `common/functions`.

- `FunctionDecl(name, options...)` with `FunctionDecl.Option`: `.overload(id, argumentTypes:resultType:, opts...)`,
  `.memberOverload(...)`, `.singletonUnaryBinding(_:traits:)` / `Binary` / `Function`,
  `.disableTypeGuards(Bool)`, `.disableDeclaration(Bool)`, `.documentation(...)`.
  `OverloadDecl.Option`: `.unaryBinding`, `.binaryBinding`, `.functionBinding`, `.nonStrict`,
  `.operandTraits`, `.examples` (and the `package` `.lateBinding`, see `docs/decisions.md` § 11). Every
  declaration operation throws `DeclarationError` (typed throws) with cel-go's messages. `merging(_:)`,
  `subset(_:)`, `including/excluding(overloadIDs:)`, `addOverload`, `overloads` (declaration order),
  `overload(withID:)`, `typeParameters`, `signatureEquals/Overlaps`.
- `VariableDecl(name:type:)`, `VariableDecl(constant:type:value:)`, `.typeIdentifier(T)` (`int` : `type(int)`).
- `FunctionDecl.bindings() throws(DeclarationError) -> [FunctionBinding]` follows cel-go `Bindings()`:
  - each overload with an implementation -> a binding named by its **overload id**, wrapped in the runtime
    type guard (`isAssignableRuntime` per argument, operand traits) unless `disableTypeGuards`;
  - one bound overload -> also registered under the **function name**;
  - several -> an extra **function name** binding that dispatches over the overloads in declaration order
    (this is what parse-only evaluation calls);
  - a singleton -> one binding under the function name, with its operand traits.
- `struct FunctionBinding { name; operandTraits; unary; binary; function; isNonStrict }`.

### How the interpreter calls a function

```swift
// once per program: index the bindings of every function in the environment
let dispatcher: [String: FunctionBinding]   // keys: overload ids and function names
// per call: checked ASTs give the overload id; parse-only uses the function name
let binding = dispatcher[overloadID] ?? dispatcher[functionName]
let result = binding.call(args, functionName: functionName, overload: overloadID, exprID: id)
```

`call` is the port of the tail of cel-go `evalUnary` / `evalBinary` / `evalVarArgs`: strict bindings
return the first error argument, then merged unknowns; the implementation runs if the first argument has
`operandTraits`; otherwise receiver dispatch (`Value.receive`), else `no such overload: <fn>`. Errors are
labelled with `exprID`. `invoke(args)` calls the implementation directly.

## Standard library (`Sources/CEL/Stdlib`)

- `StandardLibrary.functions: [FunctionDecl]` and `StandardLibrary.types: [VariableDecl]` (package), the
  port of `common/stdlib/standard.go`: operators, `size`, `in`, conversions, `contains` / `startsWith` /
  `endsWith` / `matches`, timestamp and duration accessors (with optional time zone).
- `Overloads` (package): all overload ids from `common/overloads`. Operator function names are
  `Common/Operators.swift` (`Operators.add` = `_+_`, `Operators.in` = `@in`, ...).
- The logical operators, `_?_:_`, `_==_` and `_!=_` carry placeholder singleton bindings (they return
  `no such overload`); as in cel-go the interpreter special-cases them: `&&` / `||` with commutative
  error/unknown absorption, the conditional, and `==` / `!=` via `celEquals` after the strict error/unknown
  checks of cel-go `evalEq` / `evalNe`.
- Indexing via attributes is the interpreter's job and has its own messages (`index out of bounds: 5`);
  the `_[_]` binding (`Value.get`) is used for non-attribute operands.
- Time zones (`TimeZones.swift`, `TZif.swift`): `[+-]hh:mm` offsets parsed like cel-go; IANA names read
  from the system tz database like Go's `time.LoadLocation` (`/usr/share/zoneinfo`), with Foundation's
  `TimeZone` as the Darwin fallback. Linux needs tzdata installed; no Foundation is used there.
- `matches` uses `CELRegex` (`Regexp.matchString`, Go `regexp` semantics, Go error messages).

## Containers (`Sources/CEL/Containers`)

`Container` (cel-go `containers.Container`): `Container(.name("a.b"), .abbreviations("x.y.Z"),
.alias("q.n", as: "a"))`, `extended(...)`, `resolveCandidateNames(_:)` (most qualified first, leading dot
= absolute, aliases win). `Container.qualifiedName(of: expr)` is cel-go `ToQualifiedName`.

## Parser (`Sources/CEL/Parser`)

The lexer, cel-go's generated parser and the parts of the antlr4-go runtime it uses (`ANTLR/`) are ported
by hand; `Parser` (package, `Sendable` struct) runs a per-parse `ParserRuntime` and the visitor that builds
the AST.

- **Prediction cache** (`ANTLR/PredictionCache.swift`, decision 9 in `docs/decisions.md`): ANTLR's adaptive
  prediction memoizes in one DFA per grammar decision. antlr4-go keeps them in a process-wide static; here
  a `Parser` owns a `PredictionCache`, created with it and shared by its copies, by the `Environment`
  holding it and by environments `extending` that one. The DFAs depend only on the grammar, so parser
  options do not matter. There is no process-wide state: a cache lives as long as the environments using
  it, and `DFA.deinit` breaks the DFA's edge cycles when it goes.
- **Locking** is antlr4-go's: `stateLock` guards each DFA's state set and start state, `edgeLock` the
  edges between states, both read-write locks (pthread, since `Synchronization` is above the macOS 13
  floor), taken in that order. Target states are computed outside the locks from the immutable configs of
  published states; publishing a state finds an equal one another parse may have added first. The
  invariants that make `PredictionCache: @unchecked Sendable` sound are listed on the class.

## Type checker (`Sources/CEL/Checker`)

Ported from cel-go `checker` (all of it but `cost.go` and the protobuf-typed `FormatCheckedType` /
`checker/decls`). Everything is `package` for now.

```swift
var env = CheckerEnv(container: try Container(.name("pkg")), provider: registry,
                     options: [.crossTypeNumericComparisons(true)])   // also .jsonFieldNames, .validatedDeclarations(env)
try env.addFunctions(StandardLibrary.functions)  // merges overloads; DeclarationError on conflicts / macro overlap
try env.addIdents(VariableDecl(name: "x", type: .int))
let (checked, errors) = Checker.check(parsed, source: source, env: env)   // errors: CELErrors, cel-go text
Checker.print(checked.expr, checked: checked)    // checker_test.go debug format: `x~int^x`, `_+_(...)~int^add_int64`
```

- **Checked AST** (`AST/ReferenceInfo.swift`): `AST.typeMap: [Int64: CELType]` and
  `AST.referenceMap: [Int64: ReferenceInfo]`, filled by the checker; `type(of:)` (`dyn` when absent),
  `overloadIDs(of:)`, `reference(of:)`, `isChecked`. `ReferenceInfo { name; overloadIDs; value: Value? }`:
  identifiers carry their fully qualified name (and the enum value for enum constants), calls every
  matching overload id. The interpreter's planner reads these as cel-go's reads `ast.ReferenceInfo`.
- **Rewrites**: identifiers and `a.b.c` chains that resolve to a declaration become one fully qualified
  `.ident` (leading `.` when a local shadows it), namespaced calls `a.b.f(x)` become global calls to
  `a.b.f`, message literal names become fully qualified. Offsets of removed nodes are cleared.
- Types are `CELType`; `checkerDescription` is cel-go `FormatCELType` (`!error!`, `wrapper(int)`, `_var0`).
  Unification (`CheckerTypes.swift`, `Mapping.swift`) is a value-typed port of cel-go's `types.go`.
- cel-go quirks kept: cross-type numeric comparisons are off by default but allowed inside
  comprehensions (cel-go's scoped environments drop the filter); `homogeneousAggregateLiterals` exists but
  cel-go enforces it with a `cel`-package validator.
- Tests: `Tests/CELTests/CheckerTests.swift` runs cel-go's full `checker_test.go` table, generated into
  `Fixtures/CheckerCases.swift` by `tools/checker-cases/gen.sh`, against CELProtobuf's `CELGoTestProtos`.

## Interpreter (`Sources/CEL/Interpreter`)

Ported from cel-go `interpreter/` node for node; `docs/divergences.md` § Interpreter lists the differences.

- **Planning** (`Planner.swift`, cel-go `planner.go`): `Planner.plan(expr)` walks a parsed or checked AST
  once and builds a tree of `Interpretable`s (`Interpretable.swift`): `EvalConst`, `EvalAnd` / `EvalOr`,
  `EvalEq` / `EvalNe`, `EvalUnary` / `EvalBinary` / `EvalVarArgs` / `EvalZeroArity` calls, list / map /
  message constructors, `EvalFold` for comprehensions, and `EvalAttr` for anything that reads a variable.
  Checked ASTs supply overload ids and fully qualified names through `referenceMap`; parse-only ASTs fall
  back to the function name and container-relative "maybe" attributes. Every node passes through the
  decorators (`Decorators.swift`: `OptOptimize` constant folding of literals and `in` lists, exhaustive
  evaluation, state observation, the regex program size limit, library decorators such as `optional.or`).
- **Interpretables are immutable final classes** with one entry point, `eval(_ frame: ExecutionFrame)`,
  so a planned program is `Sendable` and can be evaluated concurrently. `ExecutionFrame` holds the
  activation, comprehension-local variables (a frame per comprehension scope) and the shared `EvalContext`
  (state, cost tracker, interrupt check).
- **Attributes** (`Attributes.swift`, `AttributePatterns.swift`): absolute, maybe, relative and
  conditional attributes with constant (field or value) and computed qualifiers resolve
  `a.b["c"][0]` against the activation in one pass, produce cel-go's `no such key` / `index out of
  bounds` errors, and, with partial evaluation, match `AttributePattern`s to return `UnknownSet`s. Adding a
  qualifier returns a new attribute.
- **Activations** (`Activation.swift`): `MapActivation`, `LazyActivation` (bindings computed on first
  use), `HierarchicalActivation` and `PartialActivationWrapper` (unknown patterns). The public `Variables`
  builds one.
- **Dispatch** (`Dispatcher.swift`): overload id or function name to `FunctionBinding`, built once per
  environment; see "How the interpreter calls a function" above.
- **Comprehensions** (`EvalFold`) accumulate into `MutableList` / `MutableMap` (`MutableValues.swift`)
  and check the interrupt every `interruptCheckFrequency` iterations; two-variable comprehensions use the
  same node. `cel.@block` is a decorator contributed by `CELExtensions`.
- **Cost** (`RuntimeCost.swift`): the runtime cost tracker of cel-go `runtimecost.go`, with library
  trackers by overload id and the cost limit; the static estimator is `Checker/Cost*.swift`.
- **State and residuals**: `EvalState.swift` records per-node values for `trackState`;
  `Prune.swift` (cel-go `PruneAst`) turns an evaluated AST plus its state into a residual AST.
- `Program.swift` holds the package-level `ProgramEnvironment` (`parse` / `check` / `program`), which the
  public `Environment` wraps and the conformance runner and older tests use directly.

## Libraries (`Sources/CEL/Library`, `Sources/CELExtensions`)

A `Library` (cel-go `Library` / `SingletonLibrary`) is a value describing what an environment option
would install: function declarations with their bindings, variables, types to register, parser macros
and parser options, planner decorators, static cost estimators and runtime cost trackers, AST validators,
required libraries, and the functions exempt from the homogeneous-literal validator. Its public surface is
only `name` (`cel.lib.ext.strings`), `alias` (`strings`, the config-file name) and `version`; everything
else is `package`, so `CELExtensions` and `CELPolicy` can build libraries and clients cannot.

- `Environment.Configuration.apply(_:)` installs a library: libraries are singletons by name (the first
  wins, as in cel-go), required libraries must already be configured, functions merge into existing
  declarations, macros are appended (a later macro with the same key replaces an earlier one).
- `Library.standard` is the standard library; `Library.standard(subset:)` restricts it with a
  `Library.Subset` (cel-go `StdLibSubset` / `env.LibrarySubset`: include or exclude macros, and
  functions or single overloads by id). `Library.optionalTypes(version:)` lives in `CEL` because the
  parser and the checker know about optionals.
- `CELExtensions` adds the cel-go `ext` libraries as static factories on `Library` (`.strings(version:)`,
  `.lists`, `.math`, `.sets`, `.encoders`, `.bindings`, `.twoVarComprehensions`, `.protos`, `.network`,
  `.regex`), their macros and validators. The ported Go standard library pieces they need
  (`strings`, `strconv` float formatting, `net/netip`, base64) are in that target too.

## Public API (`Sources/CEL/API`)

`Environment` (cel-go `Env`) is an immutable value built from `Environment.Option`s: the checker
environment, parser and dispatcher are built eagerly, so declaration errors are thrown by the initializer
and `extending(_:)` reuses the parent's validated declarations when no function changed.
`parse` / `check` / `compile` return `ParsedExpression` / `CheckedExpression` (both wrap the package `AST`
and source), `program(_:options:)` returns a `Sendable` `Program`, and `evaluate` returns an
`EvaluationResult` (value, cost, state). Errors are `CompileError` (cel-go `Issues`) and `EvalError`.
`partialVariables`, `UnknownPattern`, `residual(of:state:)` (cel-go `ResidualAst`) and
`estimateCost(_:sizeHints:)` cover partial evaluation and cost; `Program.Option.globals` gives variables
default values. `Library.standard(subset:)` is the standard library restricted by a `Library.Subset`.

Optimizers (cel-go `StaticOptimizer`, `optimizer.go`, `folding.go`, `inlining.go`):
`env.optimize(checked, .constantFolding(), .inlining(...))` applies `ExpressionOptimizer`s in order,
renumbering ids and type-checking again after each. The `OptimizerContext` owns the AST being optimized
and addresses nodes by id: cel-go mutates shared nodes in place (`SetKindCase`), here `updateExpr(_:_:)`
replaces the node with a given id, keeps the macro-call metadata consistent the way cel-go's `UpdateExpr`
does, and the factory methods (`newCall`, `newBindMacro`, `copyASTAndMetadata`, ...) mirror cel-go's
`optimizerExprFactory`. Constant folding records the value of each folded node by id
(`literalValues`), which stands in for cel-go literal nodes that can hold any value.

## Command line tool (`Sources/cel-swift`)

`cel-swift eval | check | parse | repl | policy test`, built on the public API plus a few `package` debug
printers; `policy test` lives in `CELCommandLine` so `CELTestTests` can run it too.
Each subcommand is a `Command` value listed in `Command.all`; `Arguments` is a small stdlib-only parser and
`Session` builds the environment from the shared options (`--container`, `--ext NAME[:VERSION]`,
`--declare NAME:TYPE`, `--let NAME=EXPR`, `--json FILE`). The REPL follows cel-go `repl` for variables
(`%let`, `%declare`, `%delete`, `%eval`, `%parse`, `%compile`, `%option`, `%status`).

## Protobuf (`Sources/CELProtobuf`, `Sources/protoc-gen-cel-swift`)

Ported from cel-go `common/types/pb` and the protobuf half of `common/types/provider.go` / `object.go`.
swift-protobuf has no dynamic messages, so the descriptor walk cel-go does at runtime happens at build time:

- `protoc-gen-cel-swift` (a protoc plugin on `SwiftProtobufPluginLibrary`, run next to `protoc-gen-swift`
  with the same `Visibility` / `FileNaming` / `ProtoPathModuleMappings` options) writes `foo.cel.swift`
  per `foo.proto`: one `ProtobufFile` constant `<Prefix><File>_CELFile` with the file's message types
  (field tables), enum values, extensions, its swift-protobuf extension map and its imports.
- A field is `ProtobufField<M>.singular / .repeated / .map(name, number:, jsonName:, keyPath, kind,
  presence:)`: a key path into the swift-protobuf property plus a `ProtobufValueKind` (`.int32`, `.uint64`,
  `.float`, `.bytes`, `.enumeration`, `.message`, ...) that converts values both ways with cel-go's
  `ConvertToNative` rules (int32 range checks, `null` leaves message fields unset, JSON mapping for
  `Value`/`Struct`/`ListValue`, packing for `Any`). Presence is `.implicit` (proto3 non-zero, Go's -0.0 rule),
  `.explicit(\.hasX)` or `.oneof { ... }`.
- `ProtobufTypes` is the database (cel-go `pb.Db`) and implements `TypeProvider` and `TypeAdapter`; compose
  it under a `TypeRegistry` with `TypeRegistry(composing: protos, adapter: protos)`. Well-known type files
  (generated into `Sources/CELProtobuf/WellKnownTypes`) are always included; registering a file registers
  its imports.
- `ProtobufObject` (`ObjectValue`) wraps a message with its type and the `ProtobufTypes` it came from (for
  `Any` unpacking). Field access unwraps well-known types (unset wrappers / `Any` / `Value` read as `null`);
  equality is `pb.Equal` (NaN unequal, `Any` unpacked, unknown fields grouped by number).
- `ProtobufTypes.value(of:)` converts a host message to a CEL value; `message(from:as:)` converts back
  (cel-go `ConvertToNative` to a proto type, including packing into `Any`). Converting a message to JSON
  (`google.protobuf.Value`) encodes it with swift-protobuf, then each field's `patchJSON` corrects the
  places where protojson differs (NullValue is always `null`, undeclared proto2 enum numbers).
- Enums: `.enumeration("pkg.Enum")` carries the enum's name, so with strong enums
  (`Environment.Option.strongEnums`, which switches the provider via the package `StrongEnumProvider`
  protocol) fields read and accept `EnumValue`s. Fields of closed (proto2) enums keep undeclared numbers
  in the message's unknown fields (`ClosedEnumFields.swift`), as cel-go keeps any int32.
- `CELSpecProtos` holds the conformance messages with their adapters, `CELSpecProtos.protobufTypes`, and
  `Cel_Expr_Value` / `Cel_Expr_ExprValue` conversions (cel-go `cel/io.go`). `CELGoTestProtos` holds cel-go's
  `test/proto{2,3}pb` messages for ported tests. `tools/gen-protos.sh` regenerates all of them.

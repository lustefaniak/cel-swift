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
- `EvalError(message, exprID:)` is the error payload. Messages are cel-go's verbatim (`division by zero`,
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
- `protocol StructTypeDescriptor { typeName; fieldNames; fieldType(named:) -> FieldType?;
  newValue(fields:) -> Value }`: describes a message type to the checker and to `Msg{f: v}` construction.
- `FieldType { type: CELType; isSet; getFrom; isJSONField }`.
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

- `FunctionDecl(name, options...)` with `FunctionDecl.Option`: `.overload(id, argTypes:resultType:, opts...)`,
  `.memberOverload(...)`, `.singletonUnaryBinding(_:traits:)` / `Binary` / `Function`,
  `.disableTypeGuards(Bool)`, `.disableDeclaration(Bool)`, `.documentation(...)`.
  `OverloadDecl.Option`: `.unaryBinding`, `.binaryBinding`, `.functionBinding`, `.lateBinding`,
  `.nonStrict`, `.operandTraits`, `.examples`. Validation errors are `DeclarationError` with cel-go's
  messages. `merging(_:)`, `subset(_:)`, `including/excluding(overloadIDs:)`, `addOverload`,
  `overloads` (declaration order), `overload(withID:)`, `typeParams`, `signatureEquals/Overlaps`.
- `VariableDecl(name:type:)`, `VariableDecl(constant:type:value:)`, `.typeIdentifier(T)` (`int` : `type(int)`).
- `FunctionDecl.bindings() throws -> [FunctionBinding]` follows cel-go `Bindings()`:
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
= absolute, aliases win). `ToQualifiedName(expr)` belongs with the AST.

## What the interpreter must implement (not here)

Planner/attributes (variable resolution against `Container`, qualifiers, `index out of bounds`), the
special forms above, comprehensions (with a mutable accumulator), list/map/message literals (map key type
validation as cel-go; `TypeProvider.newValue` for messages), optional field selection, the
dispatcher over `FunctionBinding`s, error labelling, unknown propagation and state tracking, cost.

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
  (cel-go `ConvertToNative` to a proto type, including packing into `Any`).
- `CELSpecProtos` holds the conformance messages with their adapters, `CELSpecProtos.protobufTypes`, and
  `Cel_Expr_Value` / `Cel_Expr_ExprValue` conversions (cel-go `cel/io.go`). `CELGoTestProtos` holds cel-go's
  `test/proto{2,3}pb` messages for ported tests. `tools/gen-protos.sh` regenerates all of them.

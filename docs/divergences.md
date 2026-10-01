# Divergences from cel-go

Deliberate differences from cel-go behaviour, with the reason for each. Anything not listed here is a bug.

## CEL Policy and CELTest (YAML)

cel-go reads policies, environment configs and `tests.yaml` suites with go-yaml v3. `CELPolicy` drives
libyaml's event parser (bundled with Yams) and composes nodes with a port of go-yaml's composer and scalar
resolver, so tags, styles, positions and syntax error messages are identical; `Tests/CELPolicyTests/Goldens`
checks this against go-yaml output for all cel-go test data. The remaining differences:

- **`<<` merge keys are not expanded** when decoding environment configs and test suites. go-yaml merges
  them during `Unmarshal`; none of the cel-go configs use them, and policies (which work on raw nodes) are
  unaffected.
- **`!!binary` scalars decode as their base64 text** rather than the decoded bytes when read into a string or
  `YAMLValue`. CEL configs and tests have no use for binary scalars.
- **`null` list elements in a config decode as empty entries** (an empty `Variable`, `Function`, ...), not as
  nil pointers, so `validate()` reports `missing name` where cel-go reports `invalid variable: nil`. Swift
  models the lists as non-optional values.
- **A `null` test input binding decodes as an empty `TestInputValue`.** go-yaml stores a nil pointer, which
  celtest dereferences and crashes on.
- **`ConfigToYAML` is not ported.** Its output layout is go-yaml's emitter's, and nothing in the policy
  pipeline writes configs.
- **Model types are values.** cel-go's `Policy`, `Rule`, `Match` and `Variable` are mutable pointers shared
  with tag visitors; here they are structs and tag visitors receive them `inout`. The parse result is the
  same. Policy metadata values are `any Sendable` instead of `any`.
- **`PolicyCompiler.compile` adds optional types and the bindings library** to the environment it is
  given and returns that environment in `CompiledPolicy`. cel-go's `policy.Compile` leaves both to the
  caller and fails with an undeclared `optional.none` or `cel.@block` when they are missing; the composed
  expression always needs them, and returning the environment keeps programs from being planned without
  the `cel.@block` evaluation.
- **The static optimizer lives in `CELPolicy`** (`StaticOptimizer.swift`) and is internal: the composer is
  its only user until the core gets a public optimizer API. Swift expressions are values, so updates
  address nodes by id where cel-go mutates shared pointers.
- **`CELTest` reads only YAML.** Textproto suites, checked-expression files (`.binarypb`, `.textproto`)
  and file descriptor sets are not supported; message types come from an environment option (generated
  `CELProtobuf` types). Coverage reporting is not ported.
- **`cel-swift policy test` applies `--cel-go-test-fixtures` types before the configs.** celtest's flags
  apply the configs before any other option, which works for cel-go only because the descriptor set flag
  registers types first; `tools/celtest-go` runs cel-go with the same order as the Swift command.

## CELRegex (port of Go `regexp` and `regexp/syntax`, Go 1.26)

Matching semantics, error messages, byte offsets and the Unicode tables (Unicode 15.0.0, dumped
from Go's `unicode` package by `tools/gen-unicode-tables`) are Go's. The differences are in the API
surface and in mechanics that do not change results:

- **No `io.RuneReader` entry points** (`MatchReader`, `FindReaderIndex`, `FindReaderSubmatchIndex`)
  and no `MustCompile`, `Copy` or `encoding.Text(Un)Marshaler` methods. CEL never reads from a
  reader, and Swift callers use `try`. Go tests that only exercise these are not ported.
- **`findAll*` return an empty array where Go returns `nil`.** Go's nil and empty slices both have
  length 0 and cel-go only checks the length. The single-match `find*` methods keep Go's
  distinction with optionals (`nil` = no match).
- **`Longest()` is a settable `longest` property** on the `Regexp` value type.
- **Invalid UTF-8 in error messages.** `Syntax.ParseError.expr` is a Swift `String`, so the raw
  invalid bytes Go would echo for `invalid UTF-8` errors appear as U+FFFD. Patterns from CEL are
  Swift strings and cannot contain invalid UTF-8, so CEL never sees the difference.
- **`Regexp.programSize(_:)` does not crash on counted repetitions.** cel-go's
  `types.RegexProgramSize` (used by `RegexProgramSizeLimit`) calls `syntax.Compile` without
  `Simplify`, and Go's compiler panics on `OpRepeat` (`a{2}`). The port compiles the simplified
  tree for such patterns, reporting the size of the program that actually runs; patterns without
  counted repetition get exactly Go's number.
- **No machine pools.** Go caches matchers in `sync.Pool`s; the port allocates them per call, since
  the package has no global mutable state.
- **No recursion over trees or programs.** Go recurses freely (its stacks grow), and accepted
  patterns can produce trees 1000 levels deep (the parser's height limit, or alternation factoring
  of `....x|....y`) and simplified trees several thousand deep (`x{0,1000}` nests 2000 levels).
  Swift threads other than the main one have 512 KB stacks, so every such walk (parser size and
  height checks, alternation factoring, `Simplify`, `Equal`, `String`, `MaxCap`/`CapNames`, the
  compiler, `minInputLen`, the one-pass analysis, `machine.add`, and releasing a tree) runs on an
  explicit stack. Each keeps Go's visiting order and side effects, so trees, programs, node reuse
  and match priority are unchanged; `StackDepthTests` covers the limits.

## Values, types, declarations and the standard library

Results, error messages and Go formatting (`string(double)`, durations, RFC 3339) are cel-go's and pinned
by fixtures generated from cel-go (`tools/value-fixtures`). The differences:

- **No `ConvertToNative` and no reflection-based adaptation.** Host data becomes CEL values through the
  `ListValue` / `MapValue` / `ObjectValue` protocols (lazy) or `TypeRegistry.nativeToValue` (scalars, and
  arrays and dictionaries converted eagerly, since `Any` is not `Sendable`). Go struct reflection
  (`NativeTypes`) is replaced by conformances, later by a macro.
- **List concatenation materializes** an `ArrayList` instead of cel-go's `concatList` view; results are the
  same. Maps iterate in insertion order (`OrderedMap`) instead of Go's randomized map order.
- **`CELType` has no trait mask.** Built-in traits are derived from the kind; objects report their own
  through `ObjectValue.traits`. `TypeRegistry.register` therefore only detects conflicts by type
  equivalence, not cel-go's "type registered with conflicting traits".
- **`TypeRegistry` has no protobuf database.** Message types are registered as `StructTypeDescriptor`s and
  enum values by name (`registerEnumValue`); `CELProtobuf` supplies both.
- **No async bindings and no `Documentation()` / exprpb conversions.** `LateFunctionBinding` is kept as
  `.lateBinding` with cel-go's validation; `AsyncBinding` is not ported. Declaration doc strings are
  stored but not rendered into cel-go's `common.Doc` signatures yet.
- **`size_calc.go` (aggregate value sizes for cost tracking) is not ported** with the value layer; it
  belongs to the cost work (M4).
- **Time zones** are read from the system tz database (`/usr/share/zoneinfo` and Go's other Unix
  locations) like Go's `time.LoadLocation`. Go's embedded `time/tzdata` has no counterpart, so on a system
  without tzdata IANA names report `unknown time zone`. On Darwin, Foundation's `TimeZone` is a fallback
  when the directory is unreadable (iOS sandboxes). FoundationEssentials alone cannot resolve zone names on
  Linux, which is why Foundation is not used there. Zones are not cached: each accessor call with a zone
  name reads the TZif file.
- **`duration.getMilliseconds()` is the milliseconds portion** (`duration('1.234s')` gives 234), as the
  spec defines it and cel-cpp implements it (`timestamps/duration_converters/get_milliseconds`). cel-go
  converts the whole duration to milliseconds (1234) and skips that conformance test. Negative durations
  give a negative portion (`-1.5s` gives -500).

## Type checker

The checker is cel-go's `checker` package; messages, type inference and the debug printer output match
cel-go (the full `checker_test.go` table passes). Quirks kept on purpose because they are observable:
comprehension scopes drop the cross-type numeric comparison filter and the JSON field name option, as
cel-go's `enterScope` / `exitScope` do, so `[1].all(x, x < 2.0)` type-checks even without the option. The
differences:

- **Type variables are numbered in first-use order.** cel-go instantiates an overload's type parameters in
  Go map iteration order, so `_varN` numbering for overloads with several parameters is random there. It
  only shows in error messages that mention unresolved type variables.
- **`FormatCheckedType` (for `cel.expr.Type` protos) and `checker/decls` are not ported**: the core has
  no protobuf types. `CELType.checkerDescription` is `FormatCELType`, which produces the same strings.
- **Expressions in two error messages are rendered with the debug printer.** `incompatible type already
  exists` and `unsupported optional field selection: <expr>` print a Go struct with `%v` in cel-go; neither
  can be produced by parsed input.
- **`TestCheckInvalidLiteral` has no counterpart**: `Constant` cannot hold a duration literal.
- **List and map literal element types join `null` and wrappers as the spec does.** When an element is
  `null` and the earlier elements have a nullable type (message, duration, timestamp, wrapper, optional),
  the joined type stays the nullable one: `[msg, null][0]` is `msg`'s type and `[optional.of(1), null]` is
  `list(optional_type(int))`. A primitive joined with its wrapper gives the wrapper in either order:
  `[1, msg.single_int64_wrapper]` is `list(wrapper(int))`. cel-go's `mostGeneral` deduces `null_type` and
  `list(int)` for these and skips the five `type_deductions` tests that cover them; cel-cpp passes them.

## Parser, AST and unparser

The parser reproduces cel-go's ids, offsets, macro calls and syntax error messages byte for byte
(`Tests/CELTests/ParserFixtures`, generated by `tools/parsedump` from cel-go, covers parser_test.go, every
conformance expression and 3000 mutated inputs). The remaining differences:

- **Expressions are values.** cel-go's `ast.Expr` is a mutable interface; here `Expr` is a struct with an
  `Expr.Kind` enum. `SetKindCase` is assignment to `kind`; `Copy` is a plain copy.
- **ASTs built from syntax errors drop invalid struct field and map entry initializers.** cel-go leaves nil
  entries in the slice (which its own debug printer cannot print); here they are omitted. Such ASTs come
  with errors and are not meant to be used.
- **The unparser's error for a comprehension without a recorded macro call** names the expression with its
  debug string; cel-go prints `%v` of a pointer.
- **Deeply nested input is parsed on a dedicated thread with a large stack.** Go grows goroutine stacks;
  Swift threads have fixed stacks, so when an input's nesting could exceed a small stack budget the parse
  runs on a temporary thread sized for it and the caller waits. Results are identical.

## Protobuf (`CELProtobuf`)

cel-go reflects over protobuf descriptors (`pb.Db`, `dynamicpb`); swift-protobuf has no dynamic messages, so
`protoc-gen-cel-swift` generates a field table per message instead. The differences:

- **Only generated types.** A message type is known when its `.proto` file was compiled with
  `protoc-gen-cel-swift` and registered (`ProtobufTypes(files:)`); there is no `RegisterDescriptor` for a
  runtime `FileDescriptorSet`. The well-known types are always registered, including `FieldMask` (cel-go
  only has it when a registered file imports it).
- **Closed (proto2) enums reject undeclared numbers.** cel-go stores any int32 in a proto2 enum field; a
  swift-protobuf closed enum cannot hold an undeclared value, so assigning one is an `invalid enum value`
  error. Open (proto3) enums keep unknown numbers as in cel-go.
- **Extension equality covers registered extensions only.** `pb.Equal` ranges over every set field; here
  extension fields take part in equality when their file is registered. Unknown fields are compared as
  cel-go does (bytes, then grouped by field number).
- **Map fields and `Struct` iterate in sorted key order** instead of Go's randomized map order.
- **Error texts mention proto type names, not Go reflect types**, e.g. `unsupported type conversion from
  'double' to int64` where cel-go prints `... to int64` via `reflect.Type`; the prefixes cel-go tests match
  (`field type conversion error`, `unsupported field type`, `type conversion error`, `no such field`,
  `unknown type`) are the same.

## Interpreter

Planning and evaluation follow cel-go `interpreter/` node for node (same attribute resolution, error
messages, error node ids, observed ids and runtime cost). The differences:

- **Map literals reject non-key types and repeated keys.** cel-go accepts any value as a map literal key and
  lets a repeated key overwrite the earlier entry (it skips `fields/qualified_identifier_resolution/map_key_*`
  and `map_value_repeat_key*`). The spec makes both an error, and `MapKey` cannot hold a `double`, `null` or
  list key, so `{1.5: 1}` is `unsupported key type: double` and `{1: 'a', 1u: 'b'}` is
  `Failed with repeated key: 1` (repeats are found with CEL's cross-numeric key equality).
- **The cost limit does not unwind immediately.** cel-go panics out of evaluation when the runtime cost
  exceeds the limit. Here the cost tracker marks the evaluation cancelled and stops counting, comprehensions
  stop at their next iteration, and the program returns `operation cancelled: actual cost limit exceeded`.
  Work outside comprehensions is bounded by the expression size, so the result and the reported cost are the
  same; the remaining non-loop nodes still run.
- **Unknown pattern matching is deterministic.** When several attribute patterns could match, cel-go tries
  them in Go map order; here in the order they were given.
- **No asynchronous functions, object pools or V1 interpretables.** `async.go`, the `sync.Pool`s of
  `frame.go` and the `Interpretable` / `InterpretableV2` split have no counterpart: there is one
  `eval(_ frame:)`. Interpretables and attributes are immutable classes and adding a qualifier returns a new
  attribute, so a planned program is `Sendable`.
- **Comprehension accumulators are reference types.** `MutableList` / `MutableMap` (cel-go `mutableList` /
  `mutableMap`) are `@unchecked Sendable`: each is created by one comprehension evaluation, reachable only
  through its accumulator variable, and converted to an immutable list or map before the comprehension
  returns.
- **Pruned optionals are calls, not literals.** cel-go's `PruneAst` writes a known optional value as a
  literal holding an optional constant, which its unparser prints as `optional.of(x)`; `Constant` has no
  optional case, so the residual AST contains the calls `optional.of(x)` / `optional.none()` instead. The
  unparsed residual is the same. Pruned list optional indices are sorted (cel-go uses Go map order).
- **Deep expressions are planned, checked and evaluated on a large stack.** Like the parser (see
  `LargeStack`), `ProgramEnvironment` runs the checker, the planner and evaluation on a thread with a stack
  sized for the expression depth when the calling thread's stack may not suffice; Go has growable stacks.
- **An optional value in the middle of a select path is selected into.** cel-go's `applyQualifiers`
  unwraps an optional only at the root of an attribute, so `{'foo': optional.none()}.foo.bar` fails with
  `no such key: bar` (it skips `optionals/optionals/map_optional_select_has`). The checker already types
  that selection as optional, and the spec and cel-cpp treat it like `.?bar`: here the result is
  `optional.none()` and `has(...)` of it is `false`; `{'foo': optional.of({'bar': 1})}.foo.bar` is
  `optional.of(1)`.

## Extensions (`CELExtensions`)

- **`string.format` before strings version 4 formats `%f` and `%e` with en-US symbols only.** cel-go
  formats them through `golang.org/x/text/message` with the CLDR symbols of the configured locale
  (`ext.StringsLocale`, e.g. `de_DE` prints `3,140`). The `locale` argument of `Library.strings` is
  accepted, but only the en-US tables are ported; the x/text quirks (`%e` ignoring the precision for
  digits, superscript exponents, unsigned negative zero) are kept. From version 4 the clauses follow the
  spec and no locale applies, as in cel-go.
- **`%s` of bytes that are not valid UTF-8 prints U+FFFD** (strings version 4 and later). cel-go appends
  the raw bytes to a Go string, which may then hold invalid UTF-8; Swift strings cannot, so each invalid
  sequence becomes the replacement character.
- **`ext.NativeTypes` is not ported.** It exposes Go structs to CEL through reflection; Swift clients
  implement `ObjectValue` (or use `CELProtobuf`) instead. The ported `ext` test rows that use
  `ext.TestAllTypes` are recorded as known issues for that reason.
- **Float-to-integer conversions in the extension cost trackers saturate.** A few cel-go trackers (lists,
  sets, regex) compute in `float64` and convert with `uint64(f)`, which Go leaves to the platform for values
  out of range: arm64 saturates, amd64 returns 2^63. The port follows arm64 (`goUInt64` in
  `CELExtensions/Costs.swift`); only sizes near 2^64 reach the difference.

## Public API and optimizers

- **`Library.standard(subset:)` throws.** cel-go validates a `StdLibSubset` when the library option is
  applied to an environment; here the factory validates it, so an invalid subset is reported where it is
  built, with cel-go's messages.
- **Constant folding writes folded values in literal syntax as soon as they are folded.** cel-go keeps a
  folded value in a literal node that can hold any value and converts all of them to CEL syntax
  (`[1, 2]`, `duration("1s")`, `optional.of(1)`) in a final pass. `Constant` holds only scalars, so the
  folder records each folded node's value by id and gives the node its literal syntax at once; the
  matchers treat recorded nodes as literals and never look inside them, which reproduces cel-go's
  decisions. The optimized output of every ported `folding_test.go` and `inlining_test.go` row is the
  same.
- **No `OptimizeWithSource` and no custom `ASTOptimizer`s.** The optimizer context needs the package-level
  AST, which is not public (an open API decision), so only the built-in folding and inlining optimizers
  are available.

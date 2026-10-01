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
- **`machine.add` uses an explicit work stack** instead of recursion, so very large programs cannot
  overflow the (fixed-size) native stack. Threads are added in the same order, so match priority
  is unchanged.

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

# oracle

A small Go program that answers CEL `parse`, `check` and `eval` requests with cel-go (the
`third_party/cel-go` submodule, v0.32.0, wired in with a `replace`). The differential tests and anyone
porting a cel-go component use it as the reference. It is CI and dev tooling only, never part of the Swift
package.

```sh
cd tools/oracle
go build .                           # GOPROXY=off works once the module cache is warm
echo '{"kind":"eval","expr":"1 + 2"}' | ./oracle
go test ./...                        # smoke tests; go test -run TestSmoke -update rewrites the golden file
```

## Protocol

One JSON object per line on stdin, one response per line on stdout, flushed after each line, in order. The
process keeps running until stdin closes, so a test driver can start it once and stream requests.

### Request

| Field | Kinds | Meaning |
|---|---|---|
| `id` | all | echoed back verbatim |
| `kind` | all | `parse`, `check` or `eval` |
| `expr` | all | the CEL source |
| `profile` | all | `default` (or absent): `cel.NewCustomEnv(cel.FromConfig(config))`, i.e. the standard library and standard macros plus whatever `config` adds. `conformance`: exactly the environment of cel-go's `conformance/conformance_test.go` (stdlib, optionals, bindings, encoders, lists, math, protos, strings, two-variable comprehensions, the `cel.block` test macros, identifier escapes, `TestAllTypes` proto2 + proto3). |
| `config` | all | cel-go's environment config (`common/env.Config`, the same schema as cel-go's YAML env files) written as JSON: `container`, `variables`, `functions`, `extensions`, `features`, `limits`, `stdlib`, ... Extension names are those of `ext.ExtensionOptionFactory` (`strings`, `math`, `lists`, `sets`, `encoders`, `bindings`, `protos`, `two-var-comprehensions`, `regex`, each with an optional `version`, default 0, or `"latest"`) plus `optional`, and three oracle additions: `network`, `block` (the conformance `cel.block` macros) and `test_types`. Not allowed with the `conformance` profile. |
| `test_types` | all | register the conformance `TestAllTypes` messages (proto2 + proto3) |
| `container` | all | `cel.Container(...)`, applied after the profile and config |
| `disable_macros` | all | `cel.ClearMacros()` (as `SimpleTest.disable_macros`) |
| `decls_proto` | all | list of `cel.expr.Decl` in proto JSON, applied with `cel.ProtoAsDeclaration` (as `SimpleTest.type_env`) |
| `parser` | parse | if present, parse with `parser.NewParser` directly instead of the environment's parser; see below |
| `check` | eval | `false` evaluates the parsed, unchecked AST (parse-only mode); default `true` |
| `bindings` | eval | variable name to typed value (see Value encoding) |
| `unknowns` | eval | attribute patterns to mark unknown, each `{"variable": "x", "path": [q, ...]}` where a qualifier `q` is a typed `string`, `int`, `uint` or `bool` value or the JSON string `"*"` for a wildcard. Turns on `cel.OptPartialEval`. |
| `cost_limit` | eval | `cel.CostLimit(n)` |
| `size_hints` | eval | `{"x": {"min": 0, "max": 10}}`: size estimates for the static cost estimator, keyed by the dot-joined `AstNode.Path()` |
| `residual` | eval | also track state (`cel.OptTrackState`) and report the residual expression and the unknown attribute trails (see Response) |

`parser` options map one to one to `cel.dev/cel-go/parser` options: `max_recursion_depth`,
`error_recovery_limit`, `error_recovery_lookahead_token_limit`, `error_reporting_limit`,
`expression_size_code_point_limit`, `max_expression_node_count` (0 or absent = parser default),
`populate_macro_calls` (default `true`), `optional_syntax`, `ident_escape_syntax`, `variadic_operator_asts`,
`hidden_accumulator_name` (default `false`). The macros are the environment's (`profile`, `config`,
`disable_macros`). cel-go's `parser_test.go` uses `max_recursion_depth: 32`, `error_recovery_limit: 4`,
`error_recovery_lookahead_token_limit: 4`.

Without `parser`, `parse` uses the environment's parser, exactly as `env.Parse` does: macro calls are only
recorded when the config enables the `cel.feature.macro_call_tracking` feature, so `unparse` of a macro fails
without it.

### Response

Always: `id`, `kind`. A malformed request or an internal failure sets `oracle_error` and nothing else is
meaningful. A parse or check failure sets `error` (cel-go's `Issues.String()` / `Errors.ToDisplayString()`,
the caret-snippet format) and `issues` (`message`, `line`, 1-based, `column`, 0-based, `expr_id`).

`parse`:

| Field | Content |
|---|---|
| `debug` | `debug.ToDebugString(expr)` |
| `debug_ids` | `debug.ToAdornedDebugString` with `parser_test.go`'s `kindAndIDAdorner` (its `P` column) |
| `debug_locations` | same with `locationAdorner` (`L` column) |
| `macro_calls` | `convertMacroCallsToString` (`M` column) |
| `unparse` / `unparse_error` | `parser.Unparse(expr, sourceInfo)` |
| `parsed_expr` | the `ParsedExpr` in proto JSON (proto field names) |

`check` (and `eval` when checked):

| Field | Content |
|---|---|
| `type` | `cel.FormatCELType(ast.OutputType())`, e.g. `map(string, list(int))` |
| `type_proto` | `types.TypeToProto(...)` in proto JSON, the `deduced_type` of a conformance `typed_result` |
| `checked_debug` | `checker.Print`: debug string adorned with `~type` and `^reference` (cel-go `checker_test.go` format) |

`eval`:

| Field | Content |
|---|---|
| `result` | exactly one of `{"value": V}`, `{"error": "message"}`, `{"unknown": [expr ids, ascending]}` |
| `cost` | actual runtime cost (`cel.CostTracking(nil)`), also on errors |
| `cost_estimate` | `{"min", "max"}` from `env.EstimateCost` with `size_hints`; checked mode only |
| `unknown_attributes` (in `result`) | with `residual`, for an unknown result: expression id (as a string) to its attribute trails, e.g. `{"4": ["a.b[0]"]}` |
| `residual` / `residual_error` | with `residual`: `cel.AstToString(env.ResidualAst(ast, details))`, the residual of a partial evaluation |

## Value encoding

Every value is a JSON object with exactly one key naming its CEL kind, so `1`, `1u` and `1.0` stay distinct.

| CEL | JSON |
|---|---|
| `null` | `{"null": null}` |
| `bool` | `{"bool": true}` |
| `int` | `{"int": "-12"}`: decimal string so all 64 bits survive JSON; a JSON number is accepted on input |
| `uint` | `{"uint": "18446744073709551615"}` (same) |
| `double` | `{"double": 1.5}`; non-finite and negative zero as strings: `"NaN"`, `"Infinity"`, `"-Infinity"`, `"-0"` (a string holding any number is accepted on input) |
| `string` | `{"string": "é"}` |
| `bytes` | `{"bytes": "AP8="}`: standard base64 with padding |
| `list` | `{"list": [V, ...]}` |
| `map` | `{"map": [{"key": V, "value": V}, ...]}`: entries sorted by the key's encoded JSON text, so output is deterministic and keys of any type work |
| `google.protobuf.Duration` | `{"duration": "-1.000000001s"}`: protobuf JSON form, seconds with 0, 3, 6 or 9 fractional digits. cel-go durations are int64 nanoseconds (about ±292 years) |
| `google.protobuf.Timestamp` | `{"timestamp": "2020-01-01T00:00:00.123Z"}`: RFC 3339 in UTC, fractional seconds trimmed |
| `type` | `{"type": "int"}`: the runtime type name (`list`, `map`, `null_type`, `google.protobuf.Duration`, a message name, ...) |
| `optional` | `{"optional": null}` is `optional.none()`, `{"optional": V}` is `optional.of(V)` |
| message | `{"message": {"type": "cel.expr.conformance.proto3.TestAllTypes", "value": {...}}}`: `value` is the message in proto JSON with proto field names, `binary` (results only) its deterministic wire format in base64 |

Results never contain errors or unknowns inside a value; those are the `error` and `unknown` result kinds.
Wrapper types, `google.protobuf.Struct`/`Value`/`ListValue` and `Any` reach CEL as the values cel-go
converts them to, so they come back as primitives, maps and lists.

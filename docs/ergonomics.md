# CELSwift: the Swift-idiomatic layer

`CELSwift` is a library product on top of `CEL` and `CELPolicy`. The core stays shaped like cel-go
(`docs/decisions.md`, introduction); this module is where Swift idioms live: `Codable` facts and results,
CEL types derived from Swift types, functions implemented by typed closures, programs typed on both ends,
partial evaluation and explanations as Swift values. It was designed against PRBar's rules engine
(`prbar/docs/design/review-rules.md`), the first client, and everything below is phrased in its terms.

## Name

`CELSwift`: the package is `cel-swift`, and the module reads as "CEL, the Swift way", which is what it adds.
It was one of the two names `docs/decisions.md` left open. `CELErgonomics` describes the motive rather than
the content, and `SwiftCEL` reads like a different package. No type is named `CELSwift` (decision 2: a
type named like its module shadows it), it does not clash with the executable target `cel-swift` (module
`cel_swift`), and none of its public names clash with the standard library or Foundation.

Dependencies: `CEL` and `CELPolicy` (so `CELExtensions` and Yams). Typed policies are the main PRBar use, so
splitting a Yams-free `CELSwift` from a `CELSwiftPolicy` would add a product for a client that does not
exist yet; the split can come later without breaking imports of `CELSwift`.

## What PRBar needs

From the review-rules design (sections Rules, Engine options, Reference design: CEL Policy, AI signals),
PRBar's engine has fixed stages (`select`, `plan`, `decide`, plus prompt-part `when`s), each with:

| # | Use case | From the design |
|---|---|---|
| U1 | A **typed fact schema per stage**, written once as Swift structs (`ChangeRequest`, the review result, `lists`, `signals`, `trigger`). `decide` sees facts `select` does not. | "Each stage only sees facts that exist at that point. The loader rejects e.g. `confidence` in `select`." |
| U2 | **One policy per stage, strictly checked at load**: a misspelt field, a fact of the wrong stage, a wrongly typed comparison and an output of the wrong shape fail when the file loads, with file:line:column for the app and `prbar validate`. | "Strict validation ... fails at load time, not at 2 am on a PR." "Typed outputs." Hot reload rejects a candidate snapshot "with file:line errors". |
| U3 | **Evaluate with Swift fact structs** and **decode the `then`/`output` into Swift types** (`{"rule": ..., "verdict": ...}` → a `Decision`). | Typed `then`; "every History row records the id of the rule that matched". |
| U4 | **Custom functions** in Swift: `glob(path, pattern)` over `GlobMatcher`, helpers on PR facts. | "we would register helpers like `glob(path, pattern)`" |
| U5 | **Enumerations in rules**: severities compared by rank (`review.max_severity <= severity.suggestion`), verdicts by name. | `decide` example |
| U6 | **Lazy AI signals**: evaluate with signals unknown; if decided, no request; otherwise fetch exactly the missing signals in one request and evaluate again. A failed fetch leaves the signal absent and `has()` false. | "Lazy AI signals come for free" via partial evaluation; "Missing is not false". |
| U7 | **Explain**: per stage, which rule matched and why earlier ones did not, with source positions and the values used ("line 12, `pr.additions <= 200` was false (412)"). Backs the CLI `--explain`, Settings and the MCP `explain_rules` tool. | Explain view; state tracking |
| U8 | **Errors as values for UI and CLI**: compile and evaluation problems carry the source name, line, column and a snippet; a rule that errors at evaluation says where. | Validation, hot reload |
| U9 | **Facts reference and editor field list generated from the declarations**, so docs cannot describe a field the compiler does not have. | Docs and JSON schema |
| U10 | Bounded evaluation (cost limit, time limit) on every stage program. | Termination and cost |

## The API, use case by use case

The examples use PRBar-shaped types (they are the test fixtures in `Tests/CELSwiftTests/Fixtures.swift`):

```swift
struct ChangeRequest: Codable, CELNamedType {
  static let celTypeName = "prbar.ChangeRequest"
  var repo: String
  var author: String
  var title: String
  var draft: Bool
  var labels: [String]
  var additions: Int
  var files: [String]
  var createdAt: Date
  var reviewer: String?
}
struct Signals: Codable { var mechanical: Double? }
struct SelectFacts: Codable {
  var pr: ChangeRequest
  var trigger: String
  var lists: [String: [String]]
  var signals: Signals
}
struct Selection: Codable { var rule: String; var action: String }
```

### U1: fact schemas from Swift structs

Before, with the core API, every field is declared by hand, or the facts are `dyn` maps and nothing is
checked:

```swift
// Either loose (no field checking at all) ...
let env = try Environment(
  .variable("pr", .map(key: .string, value: .dyn)), .variable("trigger", .string),
  .variable("lists", .map(key: .string, value: .list(.string))))
// ... or a hand-written StructTypeDescriptor and ObjectValue per struct, kept in sync with the Swift type.
```

After: `CELSchema` derives the CEL type of any `Decodable` type by running its `init(from:)` against a
schema-collecting decoder, so the facts struct *is* the declaration.

```swift
let env = try Environment(.variables(from: SelectFacts.self))   // pr, trigger, lists, signals
try env.compile("pr.titel == 'x'")      // ERROR: <input>:1:3: undefined field 'titel'
try env.compile("review.confidence")    // undeclared reference to 'review' (a decide-stage fact)
```

- Structs become CEL object types (`prbar.ChangeRequest`; default name `Module.Type`, or `CELNamedType`),
  registered with the environment so field selection and struct literals are checked.
  `CELCodingOptions.StructRepresentation.maps` makes them `map(string, V)` instead.
- Optional properties may hold `null`; optional scalars get the protobuf wrapper types (`String?` is
  `wrapper(string)`), which compare with plain values and `null` and make `has(pr.reviewer)` meaningful.
- `Date` → `timestamp`, `Swift.Duration` → `duration`, `Data` → `bytes`, `URL`/`UUID` → `string`, arrays
  and sets → `list`, dictionaries → `map` (int or string keys), raw-value enums → their raw type.
- `CELCodingOptions.KeyStrategy.convertToSnakeCase` exposes `headSha` as `head_sha`, consistently in the
  schema, the encoder and the decoder. PRBar's `DiffAnnotation` already names its keys `line_start` with
  `CodingKeys`, which needs no option.
- `.variable("pr", ChangeRequest.self)` declares one variable, `.types(Decision.self)` registers types only.
- Limits (documented on `CELSchema`): non-optional enum fields need `CaseIterable` (the first case stands in
  as a placeholder; every PRBar enum already is), and an `init(from:)` that validates values must accept the
  placeholders (`0`, `""`, empty collections). Failures are `DeclarationError`s naming the field path.

### U2, U3: typed programs and policies

Before:

```swift
let policy = try PolicyParser().parse(PolicySource(yaml, description: "select.yaml"))
let compiled = try PolicyCompiler().compile(policy, environment: env)
let program = try compiled.program()
let value = try program.evaluate(["pr": prAsValueMap, "trigger": "manual", ...]).value
guard let map = value.asMap, case .string(let rule)? = map["rule"], case .string(let action)? = map["action"]
else { throw ... }   // shape errors surface per PR, at evaluation time
```

After: `TypedProgram<Facts, Output>` compiles an expression or a policy against the facts schema, checks that
the result decodes as `Output`, and evaluates with Swift values.

```swift
let select = try TypedProgram<SelectFacts, Selection>(
  policy: PolicySource(yaml, description: "select.yaml"), environment: base)
let selection = try select.evaluate(facts)          // Selection(rule: "skip-drafts", action: "skip")

let usesSplit = try TypedProgram<PlanFacts, Bool>(
  expression: "pr.repo == 'acme/monorepo'", sourceName: "prbar.yaml#plan[0]", environment: base)
```

Load-time checks beyond the type checker:

- the result type must decode as `Output` (`output type int cannot be decoded as bool`);
- a first-match policy without a default match produces `optional_type(T)` and must be decoded as
  `Optional<T>` (aggregate policies produce lists and decode as arrays);
- map literal outputs are checked against `Output`'s fields: unknown keys
  (`'acton' is not a field of Selection (fields: rule, action)`), missing required fields, value types, at
  the key's position in the YAML. Struct literal outputs (`prbar.Decision{verdict: "approve"}`) are checked
  by the type checker itself, since `Output`'s types are registered.

`Program.evaluate(_:as:)` and `Value.decoded(as:)` / `Value(encoding:)` / `Variables(encoding:)` give the
same encoding and decoding to code that keeps using the core types.

### U4: typed functions

Before:

```swift
.function("glob", .overload("glob_string_string", argumentTypes: [.string, .string], resultType: .bool,
  .binaryBinding { path, pattern in
    guard let path = path.asString, let pattern = pattern.asString else { return .error(EvalError("...")) }
    return .bool(GlobMatcher.matches(path, pattern))
  }))
```

After: the CEL signature comes from the closure's types; arguments are decoded, the result encoded, and a
thrown error becomes the call's error value.

```swift
.function("glob", .overload("glob_string_string") { (path: String, pattern: String) in
  GlobMatcher.matches(path, pattern)
}),
.function("touches", .memberOverload("change_request_touches_string") { (pr: ChangeRequest, glob: String) in
  pr.files.contains { GlobMatcher.matches($0, glob) }
})
```

Arities 0 to 3 (`overload`) and 1 to 3 (`memberOverload`), as explicit generic overloads. Parameter packs
would cover any arity, but decoding a `[Value]` into a pack needs a running index inside a pack expansion,
and explicit overloads keep the type checker's diagnostics at call sites readable; four arities cover the
rules, and packs can be added later without breaking these. The factories throw `DeclarationError` when a
type cannot be described, inside the same `try` as the environment. The bindings capture the typed
implementation behind an existential, so the `@Sendable` closures capture no generic metatypes (Swift 6.2
warns about those).

### U5: enumerations

```swift
enum AnnotationSeverity: String, Codable, CaseIterable, CELValueRepresentable {
  case info, suggestion, warning, blocker
  static var celType: CELType { .int }                       // ranks compare, names do not
  var celValue: Value { .int(Int64(Self.allCases.firstIndex(of: self) ?? 0)) }
  init(celValue: Value) throws { ... }
}
let base = try Environment(.enumConstants(AnnotationSeverity.self, namespace: "severity"))
// review.findings.exists(f, f.severity >= severity.blocker)
```

`CELValueRepresentable` replaces `Codable` for one type everywhere (fields, elements, function arguments,
results, constants). Plain raw-value enums need nothing: they are their raw values, and
`.enumConstants(ReviewVerdict.self, namespace: "verdict")` gives `verdict.approve`.

### U6: lazy signals

Before: build `Variables(values, unknowns: [UnknownPattern("signals").wildcard()])`, evaluate with a
`.partialEvaluation` program, switch on `.unknown(let set)`, walk `set.expressionIDs` and
`attributeTrails(forExpressionID:)`, fetch, rebuild the variables, repeat.

After:

```swift
switch try select.evaluate(facts, unknowns: [UnknownPattern("signals").wildcard()]) {
case .value(let selection): ...
case .unknown(let missing): ...        // [signals.mechanical]
}

// or let the program drive the loop: resolve is called only while the output depends on unknowns
let selection = try await select.evaluate(facts, unknowns: [UnknownPattern("signals").wildcard()]) {
  missing, facts in
  facts.signals = try await jev.signals(missing.map(\.description), for: facts.pr)   // one request
}
```

`EvaluationOutcome<Output>` is `.value` or `.unknown(missing:)`; errors are thrown rather than a third case,
because a rule error is not a state the loop can resolve, and throwing composes with the rest of the call
site. The async variant takes `isolation: isolated (any Actor)? = #isolation` (SE-0420, available on the
6.0 floor), so the resolver runs on the caller's actor and the facts need not cross isolation domains
except through `resolve` (which requires `Facts: Sendable`). A resolver that cannot fetch a signal leaves it
`nil`; the pattern is dropped either way, so the loop ends after at most one round per pattern.

### U7: explain

Before: `.trackState`, then map `EvaluationState` ids back to source through `location(ofExpressionID:)`,
which for a composed policy points into a `cel.@block` whose nodes no longer look like the rule as written.

After:

```swift
let explanation = try decide.explain(facts)   // pr.additions = 412
print(explanation)
// decide.yaml:8:9 pr.author in lists.trusted && review.verdict == "approve" && review.confidence >= 0.85 && variables.size <= 200 -> false
//   true   pr.author in lists.trusted   (pr.author = "alice", lists.trusted = ["alice", "bob"])
//   true   review.verdict == "approve"   (review.verdict = "approve")
//   true   review.confidence >= 0.85   (review.confidence = 0.92)
//   false  variables.size <= 200   (variables.size = 442)
// decide.yaml:12:9 review.verdict == "request_changes" && review.confidence >= 0.9 && review.findings.exists(f, f.severity >= severity.blocker) -> false
//   false  review.verdict == "request_changes"   (review.verdict = "approve")
//   true   review.confidence >= 0.9   (review.confidence = 0.92)
//   false  review.findings.exists(f, f.severity >= severity.blocker)
// result: Decision(rule: "nothing", verdict: "none", flag: nil)
```

`Explanation` has one `Condition` per policy match condition (or one for an expression), in file order, with
the rule `id`, the condition and output text, line and column, its value, and its `Term`s (the operands of
`&&`, `||`, `!`, `?:`) with the facts each reads. The program runs exhaustively, so a term after a false one
still has a value; evaluation errors land in `result` instead of throwing, and the failing term shows the
error. Built on a small `package` addition to `CELPolicy`: `CompiledPolicy.rule` keeps the compiled rule
tree, whose per-match ASTs locate conditions and terms; their values are found in the composed expression's
state through the source ranges the composer copies.

### U8: errors

`ValidationError` (load) and `EvaluationError` (run) are concrete types with `issues` / `line` / `column` /
`sourceName` for a UI and a `description` in cel-go's format for a CLI, and conform to `LocalizedError`:

```
ERROR: select.yaml:4:20: undefined field 'titel'
 |     - condition: pr.titel.startsWith("chore")
 | ...................^
```

Initializers use typed throws (`throws(ValidationError)`, `throws(EvaluationError)`): the sets are closed,
since every underlying error (`CompileError`, `PolicyError`, `DeclarationError`, encoding, decoding) is
wrapped. The async resolver variant throws untyped, since it rethrows the resolver's errors.

### U9: facts reference

`CELSchema` is public: `structTypes` with each `Field`'s name, `CELType` and optionality is what a facts
reference page, the editor's field list and a JSON schema generator need, from the same declarations the
compiler uses (`TypedProgram.factsSchema`). Field documentation is not captured (it would need a macro or a
protocol requirement); PRBar can keep it beside the generator.

### U10: limits

Every `TypedProgram` initializer takes `programOptions` (`.costLimit`, `.timeLimit`,
`.interruptCheckFrequency`), applied to the evaluation, partial-evaluation and explanation programs.

## Decisions

- **Codable, not macros.** A `@CELType` macro needs swift-syntax, a heavy dependency for every client and
  slow builds; `Codable` is already on PRBar's types and gives fields, names and key strategies. Macros stay
  a future option for what `Codable` cannot see: field documentation, computed properties, non-placeholder
  validation.
- **Objects, not maps, by default.** Strict field checking is U2. Maps remain one option away.
- **Optional scalars are wrappers.** CEL's own model for nullable scalars; `has()` works on them and
  comparisons with plain values type-check.
- **No result builders.** Environment options are already a variadic list that reads as a declaration list;
  a builder would add `if`/`for` support nobody needs here and a second way to say the same thing.
- **No new core public API.** `CELSwift` uses `package` access for the AST (explanations, output checks)
  and the environment configuration (registering types). The one core change is `package var rule` on
  `CELPolicy.CompiledPolicy`.

## Not yet, and what PRBar would still need

- **Macros** (`@CELType`): field documentation for the facts reference, opting computed properties in.
- **Async evaluation of functions** (a function that awaits): CEL evaluation is synchronous by design;
  signals are the async path (U6).
- **Residual expressions as text** for "this rule still depends on `signals.risk`": the core has
  `Environment.residual(of:state:)`; a typed wrapper can come when the explain view wants it.
- **Explain selection**: the trace gives every condition's value; deciding which match "won" in nested rules
  is left to the output's `rule` field, as PRBar's design already puts the rule id in every output.
- **Policy `tests.yaml` with typed facts**: `CELTest` runs suites against `Value` inputs; a typed runner that
  decodes `input` as `Facts` would let PRBar's rule tests double as documentation with real Swift types.
- **Cost estimates from the schema**: `env.estimateCost` takes size hints by attribute path; deriving default
  hints (files, findings, labels) from `CELSchema` would make load-time cost rejection one call.
- PRBar's side: make the fact types `Codable` facts structs per stage (`InboxPR` already derives a schema,
  see `PRBarShapeTests`), conform `AnnotationSeverity` to `CELValueRepresentable` (rank), give fact types
  `CELNamedType` names (`prbar.ChangeRequest`) so error messages and struct literals do not show module names.

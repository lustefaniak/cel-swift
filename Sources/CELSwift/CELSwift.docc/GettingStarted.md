# Typed rules for a review bot

Write the facts and decisions as Swift structs, load rules written in CEL policies, and evaluate
them with Swift values.

## Overview

A pull request review bot decides in stages: whether to review a change at all, how to review it, and
what to do with the result. Each stage sees different facts, and each decision is a rule list that users
edit. This article builds the first stage, `select`, and parts of `decide`, the way a bot such as PRBar
does.

### Describe the facts

The facts of a stage are a `Codable` struct. Its properties are the variables rules can read, with their
types; nested structs become CEL object types whose fields the type checker knows.

```swift
import CEL
import CELPolicy
import CELSwift

struct ChangeRequest: Codable, CELNamedType {
  static let celTypeName = "prbar.ChangeRequest"

  var repo: String
  var author: String
  var title: String
  var draft: Bool
  var labels: [String]
  var additions: Int
  var files: [String]
  var reviewer: String?
}

struct Signals: Codable {
  var mechanical: Double?
}

struct SelectFacts: Codable {
  var pr: ChangeRequest
  var trigger: String
  var signals: Signals
}

struct Selection: Codable, Equatable, CELNamedType {
  static let celTypeName = "prbar.Selection"

  var rule: String
  var action: String
}
```

``CELNamedType`` names the object types `prbar.ChangeRequest` and `prbar.Selection` instead of the
default, the Swift type with its module. `reviewer` is optional: rules read it as `null` when it is `nil`, and
`has(pr.reviewer)` tells whether it is set.

### Compile a policy

A policy lists rules; the first whose condition holds produces the output. ``TypedProgram`` compiles it
against the facts and checks that every output decodes as `Selection`:

```swift
let policyYAML = """
  name: select
  rule:
    match:
      - condition: 'pr.title.startsWith("chore: bump ")'
        output: '{"rule": "skip-bumps", "action": "skip"}'
      - condition: pr.draft
        output: '{"rule": "skip-drafts", "action": "skip"}'
      - condition: has(signals.mechanical) && signals.mechanical > 0.9
        output: '{"rule": "skip-mechanical", "action": "skip"}'
      - output: '{"rule": "default", "action": "review"}'
  """
let select = try TypedProgram<SelectFacts, Selection>(
  policy: PolicySource(policyYAML, description: "select.yaml"), environment: Environment())
```

Mistakes surface here, when the rules load, as a ``ValidationError`` positioned in the file. A misspelt
fact:

```
ERROR: select.yaml:4:20: undefined field 'titel'
 |     - condition: pr.titel.startsWith("chore")
 | ...................^
```

and an output that does not fit `Selection`:

```
ERROR: select.yaml:5:40: 'acton' is not a field of prbar.Selection (fields: rule, action)
 |       output: '{"rule": "skip-drafts", "acton": "skip"}'
 | .......................................^
```

Use ``ValidationError/issues`` to list them in a user interface, and the description in a command line
tool.

### Evaluate

```swift
let pr = ChangeRequest(
  repo: "acme/api", author: "alice", title: "Fix the retry loop", draft: false, labels: ["bug"],
  additions: 120, files: ["Sources/Retry.swift"], reviewer: nil)
let facts = SelectFacts(pr: pr, trigger: "review_requested", signals: Signals())
let selection = try select.evaluate(facts)   // Selection(rule: "default", action: "review")
```

A typed program is an immutable `Sendable` value: load the rules once and evaluate them from any task.
Evaluation errors are thrown as an ``EvaluationError`` with the position of the sub-expression that
failed. Pass `programOptions: [.costLimit(...)]` when loading rules from people you do not fully trust.

### Add functions

Functions take Swift closures; their CEL signature comes from the closure's parameter and result types:

```swift
let base = try Environment(
  .function("glob", .overload("glob_string_string") { (path: String, pattern: String) in
    pattern.hasSuffix("/**") ? path.hasPrefix(String(pattern.dropLast(2))) : path == pattern
  }),
  .function("isBot", .overload("is_bot_string") { (login: String) in login.hasSuffix("[bot]") })
)
let botChange = try TypedProgram<SelectFacts, Bool>(
  expression: "isBot(pr.author) && pr.files.all(f, glob(f, 'Package.resolved'))", environment: base)
```

Pass the environment to every stage; each ``TypedProgram`` adds its own facts to it.

### Compare enumerations

The `decide` stage sees the review too. An enum that rules compare by rank conforms to
``CELValueRepresentable`` and is an `int`; constants name its cases:

```swift
enum Severity: String, Codable, CaseIterable, CELValueRepresentable {
  case info, suggestion, warning, blocker

  static var celType: CELType { .int }
  var celValue: Value { .int(Int64(Self.allCases.firstIndex(of: self) ?? 0)) }
  init(celValue: Value) throws {
    guard let rank = celValue.asInt, let index = Int(exactly: rank), Self.allCases.indices.contains(index)
    else { throw EvalError("not a severity: \(celValue)") }
    self = Self.allCases[index]
  }
}

struct Finding: Codable {
  var path: String
  var severity: Severity
}

struct Review: Codable {
  var verdict: String
  var confidence: Double
  var findings: [Finding]
}

struct DecideFacts: Codable {
  var pr: ChangeRequest
  var review: Review
}

let blocking = try TypedProgram<DecideFacts, Bool>(
  expression: "review.findings.exists(f, f.severity >= severity.warning)",
  environment: base.extending(.enumConstants(Severity.self, namespace: "severity")))
```

### Fetch expensive facts only when needed

Some facts cost money or time, such as a model's judgment that a change is mechanical. Mark them unknown:
when the output does not depend on them it is decided without them; otherwise the program asks for exactly
the ones it needs, once per round:

```swift
let decided = try await select.evaluate(facts, unknowns: [UnknownPattern("signals").wildcard()]) {
  missing, facts in
  // missing is [signals.mechanical]: fetch it with one request.
  facts.signals.mechanical = 0.97
}
// Selection(rule: "skip-mechanical", action: "skip")
```

For a draft the second rule decides first, and the closure is never called. A signal the closure cannot
get stays `nil`, so `has(signals.mechanical)` is false and the rule does not match.
``TypedProgram/evaluate(_:unknowns:)`` gives the same decision without the loop, as an
``EvaluationOutcome``.

### Explain a decision

``TypedProgram/explain(_:)`` evaluates every condition, down to the predicates it combines and the facts
they read:

```swift
var large = facts
large.pr.additions = 412
let rule = try TypedProgram<SelectFacts, Bool>(
  expression: "pr.additions <= 200 && !pr.draft", environment: base)
print(try rule.explain(large))
```

```
<input>:1:1 pr.additions <= 200 && !pr.draft -> false
  false  pr.additions <= 200   (pr.additions = 412)
  false  pr.draft   (pr.draft = false)
result: false
```

For a policy there is one ``Explanation/Condition`` per rule condition, with its line in the file and the
`id` of its rule.

### Use the pieces directly

``TypedProgram`` is built from parts that also work with the core API:

- `Environment.Option.variables(from:options:)` declares a facts struct's properties as variables, and
  `Environment.Option.types(_:options:)` registers struct types for struct literals and function
  signatures.
- ``CELSchema`` describes a Swift type as CEL types, for example to generate a reference of the facts a
  stage offers.
- ``CELEncoder`` and ``CELDecoder`` convert values; `Variables(encoding:options:)`,
  `Value(encoding:options:)`, `Value.decoded(as:options:)` and `Program.evaluate(_:as:options:)` are
  shortcuts.

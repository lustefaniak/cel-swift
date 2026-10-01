# ``CELSwift``

Use Swift types on both ends of CEL expressions and policies: `Codable` facts in, `Decodable` results
out, checked when the rules are loaded.

## Overview

The `CEL` and `CELPolicy` modules follow cel-go's shape: values are `Value`s, declarations are
`CELType`s. This module adds the Swift side:

- ``CELSchema`` derives CEL types from `Decodable` Swift types, so a facts struct is the declaration
  expressions are type-checked against: a misspelt field or a fact of the wrong type is a compile error.
- ``CELEncoder`` and ``CELDecoder`` convert any `Encodable` value to CEL values and results back to
  `Decodable` types, with dates, durations, data, optionals and key strategies.
- Typed overloads, `FunctionDecl.Option.overload(_:options:_:)` and `memberOverload(_:options:_:)`, implement
  CEL functions with Swift closures over typed arguments.
- ``TypedProgram`` compiles an expression or a policy against a facts type and an output type, checks
  that the outputs decode, evaluates, evaluates partially with facts fetched only when needed, and
  explains results condition by condition.

```swift
import CEL
import CELSwift

struct Facts: Codable {
  var pr: ChangeRequest
  var trigger: String
}

let rule = try TypedProgram<Facts, Bool>(
  expression: "pr.additions <= 200 && trigger == 'review_requested'", environment: Environment())
let small = try rule.evaluate(Facts(pr: pr, trigger: "review_requested"))
```

## Topics

### Essentials

- <doc:GettingStarted>
- ``TypedProgram``
- ``ValidationError``
- ``EvaluationError``

### Partial evaluation and explanations

- ``EvaluationOutcome``
- ``Explanation``

### Swift types as CEL types

- ``CELSchema``
- ``CELValueRepresentable``
- ``CELNamedType``
- ``CELCodingOptions``

### Converting values

- ``CELEncoder``
- ``CELDecoder``

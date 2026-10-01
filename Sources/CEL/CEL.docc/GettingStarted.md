# Getting started

Declare what expressions may use, compile them once, and evaluate them many times.

## Overview

Working with CEL has three steps:

1. Create an ``Environment`` with the variables, functions and libraries expressions may use.
2. Compile an expression into a ``CheckedExpression``: the environment parses it and type-checks it
   against the declarations, so mistakes surface before anything runs.
3. Create a ``Program`` from the checked expression and evaluate it with variable values.

Environments, checked expressions and programs are immutable `Sendable` values. Compile and create
programs once, then evaluate them from any thread or task.

### Declare the environment

``Environment/init(_:)`` starts from the CEL standard library: operators, `size`, `contains`,
`matches`, conversions, timestamps and durations, and the macros `has`, `all`, `exists`,
`exists_one`, `map` and `filter`. Add declarations with ``Environment/Option`` values:

```swift
import CEL

let env = try Environment(
  .variable("request", .map(key: .string, value: .dyn)),
  .variable("limit", .int),
  .constant("maxRetries", .int, value: 3)
)
```

Use ``CELType/dyn`` when a value's type is only known at runtime, such as JSON-like data. Use
``Environment/extending(_:)`` to derive an environment with more declarations without changing the
original, and ``Environment/custom(_:)`` to start without the standard library.

### Compile

``Environment/compile(_:sourceName:)`` parses and type-checks an expression. Errors are thrown as a
``CompileError`` whose description points at the problem:

```swift
do {
  _ = try env.compile("request.size > limt")
} catch {
  print(error)
  // ERROR: <input>:1:16: undeclared reference to 'limt' (in container '')
  //  | request.size > limt
  //  | ...............^
}
```

A checked expression knows its result type, which is useful to reject expressions that cannot produce
what the caller needs:

```swift
let checked = try env.compile("request.size > limit")
checked.outputType == .bool   // true
```

### Evaluate

```swift
let program = try env.program(checked)
let result = try program.evaluate(["request": ["size": 2048], "limit": 1024])
result.value          // true
result.value.asBool   // Optional(true)
```

Variable values are ``Value``s; integer, floating-point, string, boolean, array and dictionary
literals convert automatically. Runtime errors, such as a
division by zero or a missing map key, are thrown as ``EvalError``; with
``Program/Option/errorsAsValues`` they are returned as `.error` values instead.

``Variables`` can also compute values only when an expression reads them:

```swift
var variables: Variables = ["limit": 1024]
variables.bind("request") { ["size": 2048] }   // runs only if the expression reads `request`
```

### Add functions

Declare a function with its overloads and a Swift implementation:

```swift
let env = try Environment(
  .function(
    "shout",
    .memberOverload(
      "string_shout", argTypes: [.string], resultType: .string,
      .unaryBinding { value in
        guard let text = value.asString else { return .error(EvalError("expected a string")) }
        return Value(text.uppercased() + "!")
      }))
)
try env.program(env.compile("'hi'.shout()")).evaluate().value   // "HI!"
```

The extension libraries of cel-go are in the `CELExtensions` module:

```swift
import CELExtensions

let env = try Environment(.library(.strings), .library(.lists), .library(.math))
```

To expose only part of the standard library, start from a custom environment with a subset:

```swift
let subset = Library.Subset(
  includedMacros: ["has"],
  includedFunctions: [.init("_==_"), .init("_&&_"), .init("size", overloadIDs: ["list_size"])])
let small = try Environment.custom(.library(.standard(subset: subset)))
```

### Bound the cost

Every expression terminates, but a large input can still make it expensive. Limit the work a program may
do with a cost limit, and estimate an expression's cost before running it:

```swift
let env = try Environment(.variable("items", .list(.string)))
let checked = try env.compile("items.all(i, i.size() < 100)")
let range = env.estimateCost(checked, sizeHints: ["items": 0...1000, "items.@items": 0...100])
let program = try env.program(checked, options: [.costLimit(10_000)])
```

Cancelling the task an evaluation runs in stops it too, when the program checks for interrupts
(``Program/Option/interruptCheckFrequency(_:)`` or ``Program/Option/timeLimit(_:)``).

### Evaluate with missing data

With ``Program/Option/partialEvaluation``, attributes that are not known yet evaluate to an unknown
value instead of an error, and parts of the expression that do not depend on them are still decided:

```swift
let env = try Environment(.variable("user", .string), .variable("risk", .double))
let program = try env.program(
  env.compile("user == 'admin' || risk < 0.5"), options: [.partialEvaluation])
let decided = try program.evaluate(Variables(["user": "admin"], unknowns: [UnknownPattern("risk")]))
decided.value   // true, without knowing `risk`
```

### Optimize

``Environment/optimize(_:_:)`` rewrites a checked expression: constant folding evaluates everything that
does not depend on variables, and inlining replaces variables with expressions.

```swift
let env = try Environment(.variable("x", .int))
let folded = try env.optimize(env.compile("x + 2 * 3 > 10"), .constantFolding())
folded.description   // x + 6 > 10
```

### Try expressions on the command line

The `cel-swift` tool in this package evaluates, checks and parses expressions, and has a REPL:

```sh
swift run cel-swift eval --declare 'x:int' --let 'x=20' 'x * 2 + 2'
swift run cel-swift check --debug --declare 'm:map(string, int)' 'm.a + 1'
swift run cel-swift repl --ext strings
```

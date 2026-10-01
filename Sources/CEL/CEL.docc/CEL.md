# ``CEL``

Compile and evaluate Common Expression Language expressions in Swift.

## Overview

[CEL](https://github.com/google/cel-spec) is a small, side-effect free expression language for policies,
filters and validation rules: `request.auth.claims.group == 'admin' && resource.size < 1024`. Expressions
are type-checked against declarations before they run, evaluation always terminates, and its cost can be
estimated and bounded, so expressions written by users can be evaluated safely.

This module is a port of [cel-go](https://github.com/cel-expr/cel-go) and follows its behaviour, error
messages and cost model. The extension libraries (strings, lists, math, sets, encoders, network, regex,
bindings) are in the `CELExtensions` module, protobuf message support in `CELProtobuf`, and CEL policies
and test suites in `CELPolicy` and `CELTest`.

```swift
import CEL

let env = try Environment(.variable("user", .map(key: .string, value: .dyn)))
let checked = try env.compile("user.age >= 18 && user.country in ['PL', 'DK']")
let program = try env.program(checked)
let result = try program.evaluate(["user": ["age": 30, "country": "PL"]])
print(result.value)   // true
```

## Topics

### Essentials

- <doc:GettingStarted>
- ``Environment``
- ``Program``
- ``Value``

### Compiling expressions

- ``ParsedExpression``
- ``CheckedExpression``
- ``CompileError``
- ``CELType``

### Declarations and libraries

- ``VariableDecl``
- ``FunctionDecl``
- ``OverloadDecl``
- ``FunctionBinding``
- ``DeclarationError``
- ``Library``
- ``ExpressionValidator``
- ``Container``

### Evaluating

- ``Variables``
- ``EvaluationResult``
- ``EvaluationState``
- ``EvalError``

### Partial evaluation

- ``UnknownPattern``
- ``UnknownSet``
- ``AttributeQualifier``
- ``AttributeTrail``

### Optimizing expressions

- ``ExpressionOptimizer``
- ``InlinedVariable``

### Values

- ``ListValue``
- ``MapValue``
- ``MapKey``
- ``ObjectValue``
- ``EnumValue``
- ``CELDuration``
- ``CELTimestamp``
- ``ArrayList``
- ``OrderedMap``

### Custom types

- ``TypeProvider``
- ``TypeAdapter``
- ``TypeRegistry``
- ``StructTypeDescriptor``
- ``StructFieldType``
- ``TypeTraits``

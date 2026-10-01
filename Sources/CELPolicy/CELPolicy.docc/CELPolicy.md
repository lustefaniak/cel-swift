# ``CELPolicy``

Parse, compile and evaluate CEL policies written in YAML.

## Overview

A CEL policy names a rule made of variables and an ordered list of matches: the first match whose
condition holds produces the policy's output. Rules nest, and an aggregate rule collects the outputs
of every match that holds. The format and its semantics are cel-go's
[`policy` package](https://github.com/cel-expr/cel-go/tree/master/policy); the same files compile and
evaluate the same way here.

``PolicyCompiler`` composes a policy into one checked CEL expression, so everything the core offers
for expressions applies to policies unchanged: cost estimation and limits, partial evaluation with
unknowns, and state tracking. Variables become `cel.@block` slots, so each is evaluated at most once.

The variables and functions a policy may use come from an ``EnvironmentConfig``, cel-go's
environment YAML, or from any `Environment` built in code.

```swift
import CEL
import CELPolicy

let policyYAML = """
  name: pr_size
  rule:
    variables:
      - name: lines
        expression: pr.additions + pr.deletions
    match:
      - condition: variables.lines > 1000
        output: "'large'"
      - condition: variables.lines > 200
        output: "'medium'"
      - output: "'small'"
  """
let configYAML = """
  name: pr_size
  variables:
    - name: pr
      type:
        type_name: map
        params:
          - type_name: string
          - type_name: int
  """

let policy = try PolicyParser().parse(PolicySource(policyYAML, description: "pr_size.yaml"))
let env = try Environment(.environmentConfig(try EnvironmentConfig(yaml: configYAML)))
let compiled = try PolicyCompiler().compile(policy, environment: env)
let result = try compiled.program().evaluate(["pr": ["additions": 150, "deletions": 90]])
print(result.value)   // "medium"
```

Errors in the policy file, YAML or CEL, are reported as a ``PolicyError`` with positions in the
policy file, in cel-go's format.

Test suites in cel-go's `tests.yaml` format run with the `CELTest` module or with
`cel-swift policy test`.

## Topics

### Policies

- ``PolicyParser``
- ``PolicySource``
- ``Policy``
- ``PolicyError``

### Compiling

- ``PolicyCompiler``
- ``CompiledPolicy``

### Environment configuration

- ``EnvironmentConfig``
- ``EnvironmentConfigError``

### Custom tags

- ``PolicyTagVisitor``
- ``DefaultPolicyTagVisitor``
- ``PolicyParserContext``

### YAML

- ``YAMLNode``
- ``YAMLValue``
- ``YAMLError``
- ``RelativeSource``

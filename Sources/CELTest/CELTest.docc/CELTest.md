# ``CELTest``

Run cel-go's `tests.yaml` suites against CEL expressions and policies.

## Overview

cel-go's `celtest` tool checks expressions and policies against test suites written in YAML: each
test binds input variables and names the expected value, error or unknown result. This module reads
the same suites and runs them with the same semantics, so a suite passes here exactly when it passes
with `celtest`. The `cel-swift policy test` command is built on it.

A ``TestCompiler`` builds the environment from environment configs and compiles the expressions or
policies under test; a ``TestRunner`` runs a ``TestSuite`` against them:

```swift
import CEL
import CELPolicy
import CELTest

let config = try EnvironmentConfig(
  yaml: """
    name: doubling
    variables:
      - name: i
        type:
          type_name: int
    """)
let compiler = try TestCompiler(options: [.environmentConfig(config)])
let runner = try TestRunner(compiler: compiler, expressions: [compiler.compile(expression: "i * 2 == 42")])
let suite = try TestSuite(
  yaml: """
    description: doubling
    section:
      - name: valid
        tests:
          - name: twenty-one
            input:
              i:
                value: 21
            output:
              value: true
          - name: ten
            input:
              i:
                value: 10
            output:
              value: true
    """)
for result in runner.run(suite) {
  print(result.name, result.passed)
}
// valid/twenty-one true
// valid/ten false
```

<doc:RunningTestSuites> describes the suite format and how to run suites from Swift tests.

## Topics

### Essentials

- <doc:RunningTestSuites>
- ``TestCompiler``
- ``TestRunner``
- ``TestResult``
- ``TestRunnerError``

### Test suites

- ``TestSuite``
- ``TestSection``
- ``TestCase``
- ``TestInputValue``
- ``TestOutput``

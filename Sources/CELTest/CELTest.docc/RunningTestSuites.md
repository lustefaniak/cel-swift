# Running test suites

Write `tests.yaml` suites for policies and expressions, and run them from the command line or from
Swift tests.

## Overview

A suite is a list of sections, each a list of named tests. A test binds the inputs the expression or
policy reads and states the expected outcome. The format is cel-go's, so suites can be shared with
projects that run them with `celtest`.

### Write a suite

Inputs are literal YAML values (`value`) or CEL expressions evaluated in the test environment
(`expr`), useful for timestamps, durations and messages. The expected output is one of:

- `value`: a literal the result must equal;
- `expr`: a CEL expression whose result the result must equal;
- `error_set`: messages, one of which the evaluation error must contain;
- `unknown_set`: the expression identifiers the result must be unknown for. Input variables a test
  does not bind are unknown, as in `celtest`.

```yaml
description: pull request size
section:
  - name: sizes
    tests:
      - name: medium
        input:
          pr:
            value:
              additions: 150
              deletions: 90
        output:
          value: medium
      - name: large
        input:
          pr:
            expr: "{'additions': 900, 'deletions': 200}"
        output:
          expr: "'lar' + 'ge'"
```

### Run it from Swift tests

``TestCompiler/compile(policyFile:path:)`` parses and compiles a policy, and
``TestCompiler/compile(expression:)`` an expression. Each ``TestResult`` names its test as
`<section>/<test>`; ``TestResult/failureDescription`` renders a failure the way `celtest` prints it.
With Swift Testing, one expectation per test keeps failures readable:

```swift
import CEL
import CELPolicy
import CELTest
import Testing

@Test func prSizePolicy() throws {
  let compiler = try TestCompiler(options: [.environmentConfig(try EnvironmentConfig(yaml: configYAML))])
  let policy = try compiler.compile(policyFile: policyYAML, path: "pr_size.yaml")
  let runner = try TestRunner(compiler: compiler, policies: [policy])
  for result in runner.run(try TestSuite(yaml: testsYAML)) {
    #expect(result.passed, "\(result.failureDescription ?? "")")
  }
}
```

Here `policyYAML` and `configYAML` are the policy and environment config from the `CELPolicy`
overview, and `testsYAML` is the suite above.

### Run it from the command line

`cel-swift policy test` takes the same inputs and prints `celtest`'s report:

```sh
swift run cel-swift policy test --cel-expr pr_size.yaml --config config.yaml --test-suite tests.yaml
```

`--cel-expr` also accepts a `.cel` file or an expression; `--base-config` adds a config applied
before `--config`.

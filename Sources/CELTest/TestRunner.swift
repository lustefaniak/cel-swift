// Copyright 2025 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//    https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

// Ported from cel-go tools/celtest/test_runner.go (TestRunner, Programs, Tests,
// createTestsFromYAML, createTestInput, createResultMatcher, ExecuteTest, compareUnknownIDs).
//
// Not ported: textproto test suites and file descriptor sets (protobuf types come from the
// environment's type provider instead), and coverage reporting.

import CEL
import CELPolicy

/// Runs `tests.yaml` suites against compiled CEL expressions or policies, with cel-go `celtest`
/// semantics.
///
/// ```swift
/// let compiler = try TestCompiler(options: [.environmentConfig(config)])
/// let policy = try compiler.compile(policyFile: text, path: "policy.yaml")
/// let runner = try TestRunner(compiler: compiler, policies: [policy])
/// let results = runner.run(suite)
/// ```
public struct TestRunner: Sendable {
  /// The environment tests are compiled and evaluated in.
  public let environment: Environment
  /// The programs every test is run against.
  public let programs: [Program]

  /// Creates a runner for programs.
  ///
  /// - Parameters:
  ///   - environment: The environment test inputs and expected values are evaluated in; its
  ///     variables not bound by a test are unknown when the programs use partial evaluation.
  ///   - programs: The programs every test is run against. They should evaluate errors as values
  ///     (``Program/Option/errorsAsValues``).
  public init(environment: Environment, programs: [Program]) {
    self.environment = environment
    self.programs = programs
  }

  /// Creates a runner for compiled expressions and policies, as `celtest` does: programs
  /// evaluate with partial evaluation, so input variables a test does not set are unknown.
  ///
  /// - Parameters:
  ///   - compiler: The compiler that produced the expressions; its environment evaluates the test
  ///     inputs and expected values.
  ///   - expressions: Compiled expressions.
  ///   - policies: Compiled policies.
  ///   - partialEvaluation: Whether unset variables are unknown rather than missing.
  /// - Throws: ``TestRunnerError`` when an expression cannot be planned.
  public init(
    compiler: TestCompiler, expressions: [CheckedExpression] = [], policies: [CompiledPolicy] = [],
    partialEvaluation: Bool = true
  ) throws(TestRunnerError) {
    var options: [Program.Option] = [.errorsAsValues]
    if partialEvaluation {
      options.append(Program.Option { $0.evalOptions.insert(.partialEval) })
    }
    var programs: [Program] = []
    do {
      for expression in expressions {
        programs.append(try compiler.environment.program(expression, options: options))
      }
      for policy in policies {
        programs.append(try policy.program(options: options))
      }
    } catch {
      throw TestRunnerError(error.description)
    }
    self.init(environment: compiler.environment, programs: programs)
  }

  /// Runs every test of a suite against every program.
  ///
  /// - Parameter suite: The test suite.
  /// - Returns: One result per test, in suite order, named `<section>/<test>`.
  public func run(_ suite: TestSuite) -> [TestResult] {
    var results: [TestResult] = []
    for section in suite.sections {
      for test in section.tests {
        let name = "\(section.name)/\(test.name)"
        results.append(run(test, named: name))
      }
    }
    return results
  }

  /// Runs one test case against every program (cel-go `ExecuteTest`).
  ///
  /// - Parameters:
  ///   - test: The test case.
  ///   - name: The name reported in the result.
  /// - Returns: The result; the first failing program decides a failure.
  public func run(_ test: TestCase, named name: String) -> TestResult {
    let activation: any Activation
    let matcher: ResultMatcher
    do {
      activation = try makeInput(test)
      matcher = try makeMatcher(test.output)
    } catch {
      return TestResult(name: name, outcome: .failed(wanted: nil, failure: error.description))
    }
    for program in programs {
      let result = program.run(activation)
      var errorMessage: String?
      if case .error(let error) = result.value {
        errorMessage = error.message
      }
      let outcome = matcher(result.value, errorMessage)
      if outcome.isFailed {
        return TestResult(name: name, outcome: outcome)
      }
    }
    return TestResult(name: name, outcome: .passed)
  }

  // MARK: - Inputs

  func makeInput(_ test: TestCase) throws(TestRunnerError) -> any Activation {
    var bindings: [String: Value] = [:]
    if let contextExpr = test.contextExpression, !contextExpr.isEmpty {
      if !test.input.isEmpty {
        throw TestRunnerError("only one of input and input_context can be provided at a time")
      }
      let ctx = try eval(contextExpr)
      guard case .object(let object) = ctx, case .object(let typeName) = object.celType,
        let fields = environment.typeProvider.findStructFieldNames(typeName)
      else {
        throw TestRunnerError("context variable is not a valid proto: \(ctx)")
      }
      for field in fields {
        bindings[field] = object.field(field)
      }
    } else {
      for (name, input) in test.input {
        if let expr = input.expression, !expr.isEmpty {
          bindings[name] = try eval(expr)
          continue
        }
        bindings[name] = input.value.map(Value.init(yaml:)) ?? .null
      }
    }
    return partialVars(MapActivation(bindings))
  }

  /// Marks every declared variable the activation does not bind as unknown
  /// (cel-go `Env.PartialVars`).
  func partialVars(_ activation: any Activation) -> any Activation {
    var patterns: [AttributePattern] = []
    for v in environment.variables where activation.resolveName(v.name) == nil {
      patterns.append(AttributePattern(v.name))
    }
    return PartialActivationWrapper(activation, unknowns: patterns)
  }

  /// Evaluates a test expression in the environment with optional types (cel-go `tr.eval`).
  func eval(_ expression: String) throws(TestRunnerError) -> Value {
    do {
      let env = try environment.extending(.optionalTypes)
      let checked = try env.compile(expression)
      let program = try env.program(checked)
      return try program.evaluate().value
    } catch {
      throw TestRunnerError("eval(\(goQuoted(expression))) failed: \(error)")
    }
  }

  // MARK: - Matchers

  typealias ResultMatcher = (Value, String?) -> TestResult.Outcome

  func makeMatcher(_ output: TestOutput?) throws(TestRunnerError) -> ResultMatcher {
    guard let output else {
      throw TestRunnerError("expected output is nil")
    }
    if let value = output.value {
      let want = Value(yaml: value)
      return valueMatcher(want)
    }
    if let expr = output.expression, !expr.isEmpty {
      return valueMatcher(try eval(expr))
    }
    if let errorSet = output.errorSet {
      return { _, error in
        let failure = TestResult.Outcome.failed(wanted: "error \(goList(errorSet))", failure: nil)
        guard let error else {
          return failure
        }
        for want in errorSet where error.utf8.contains(subsequence: want.utf8) {
          return .passed
        }
        return failure
      }
    }
    if let unknownSet = output.unknownSet {
      return { value, error in
        if error == nil, case .unknown(let unknown) = value {
          let got = unknown.expressionIDs.sorted()
          let want = unknownSet.sorted()
          if got == want {
            return .passed
          }
          return .failed(
            wanted: "unknown value \(goList(unknownSet))",
            failure: "mismatched test output: got unknown value \(goList(got))")
        }
        return .failed(wanted: "unknown value \(goList(unknownSet))", failure: error)
      }
    }
    throw TestRunnerError("expected output is empty")
  }

  func valueMatcher(_ want: Value) -> ResultMatcher {
    { out, error in
      let wanted = "simple value \(want)"
      if let error {
        return .failed(wanted: wanted, failure: error)
      }
      if case .bool(true) = out.celEquals(want) {
        return .passed
      }
      if case .optional(let inner?) = out, case .bool(true) = inner.celEquals(want) {
        return .passed
      }
      return .failed(wanted: wanted, failure: "policy eval got \(out)")
    }
  }
}

/// The outcome of one test.
public struct TestResult: Sendable, Hashable {
  /// Whether the test passed, or what was wanted and what went wrong.
  ///
  /// A struct rather than an enum so that later kinds of outcome (a skipped test, say) can be added
  /// without breaking clients: compare with ``passed`` or ask ``isFailed``, and read ``wanted`` and
  /// ``failure`` for the details.
  public struct Outcome: Sendable, Hashable {
    private enum Kind: Sendable, Hashable {
      case passed
      case failed
    }

    private let kind: Kind
    /// What the test wanted, for a failed test.
    public let wanted: String?
    /// What happened instead, for a failed test when known.
    public let failure: String?

    /// The result matched the expected output.
    public static let passed = Outcome(kind: .passed, wanted: nil, failure: nil)

    /// The result did not match: what the test wanted and, when known, what happened instead.
    public static func failed(wanted: String?, failure: String?) -> Outcome {
      Outcome(kind: .failed, wanted: wanted, failure: failure)
    }

    /// Whether the result matched the expected output.
    public var isPassed: Bool { kind == .passed }

    /// Whether the result did not match the expected output.
    public var isFailed: Bool { kind == .failed }
  }

  /// The test name, `<section>/<test>`.
  public var name: String
  /// The outcome.
  public var outcome: Outcome

  /// Whether the test passed.
  public var passed: Bool {
    outcome.isPassed
  }

  /// The failure rendered as `celtest` does: the test name, what was wanted and the failure.
  public var failureDescription: String? {
    guard outcome.isFailed else {
      return nil
    }
    return "test: \(name) \n wanted: \(outcome.wanted ?? "<nil>") \n failed: \(outcome.failure ?? "<nil>")"
  }
}

/// An error setting up a test runner or a test.
public struct TestRunnerError: Error, Sendable, CustomStringConvertible {
  /// The error message.
  public var description: String

  /// Creates an error.
  public init(_ description: String) {
    self.description = description
  }
}

extension Value {
  /// The CEL value of a decoded YAML value, as cel-go's `NativeToValue` converts go-yaml's
  /// decoded values.
  init(yaml: YAMLValue) {
    switch yaml {
    case .null: self = .null
    case .bool(let b): self = .bool(b)
    case .int(let i): self = .int(i)
    case .uint(let u): self = .uint(u)
    case .double(let d): self = .double(d)
    case .string(let s): self = .string(s)
    case .list(let items): self = .list(ArrayList(items.map(Value.init(yaml:))))
    case .map(let entries):
      var pairs: [(MapKey, Value)] = []
      for entry in entries {
        guard let key = MapKey(Value(yaml: entry.key)) else {
          self = .error(EvalError("unsupported map key type"))
          return
        }
        pairs.append((key, Value(yaml: entry.value)))
      }
      self = .map(OrderedMap(pairs))
    }
  }
}

extension Sequence where Element == UInt8 {
  func contains(subsequence needle: some Collection<UInt8>) -> Bool {
    let hay = Array(self)
    let n = Array(needle)
    if n.isEmpty {
      return true
    }
    if n.count > hay.count {
      return false
    }
    for start in 0...(hay.count - n.count) where hay[start..<(start + n.count)].elementsEqual(n) {
      return true
    }
    return false
  }
}

/// Go's `%v` rendering of a slice.
func goList<T>(_ items: [T]) -> String {
  "[" + items.map { "\($0)" }.joined(separator: " ") + "]"
}

/// Go's `%q` rendering of a string (enough for messages).
func goQuoted(_ s: String) -> String {
  "\"" + s.replacingAll("\\", with: "\\\\").replacingAll("\"", with: "\\\"").replacingAll("\n", with: "\\n") + "\""
}

extension String {
  func replacingAll(_ target: String, with replacement: String) -> String {
    let t = Array(target.unicodeScalars)
    let scalars = Array(unicodeScalars)
    var out = String.UnicodeScalarView()
    var i = 0
    while i < scalars.count {
      if i + t.count <= scalars.count, Array(scalars[i..<(i + t.count)]) == t {
        out.append(contentsOf: replacement.unicodeScalars)
        i += t.count
      } else {
        out.append(scalars[i])
        i += 1
      }
    }
    return String(out)
  }
}

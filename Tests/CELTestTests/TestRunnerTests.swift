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

// Ported from cel-go tools/celtest/test_runner_test.go, extended to every suite cel-go runs with
// celtest: the `cel_go_test` targets of policy/BUILD.bazel and tools/celtest/BUILD.bazel and the
// remaining `policy/testdata/*/tests.yaml` suites (which cel-go runs through policy/compiler_test.go).

import CEL
import CELCommandLine
import CELPolicy
import CELTest
import Foundation
import Testing

struct TestRunnerTests {
  static let celGo = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("third_party/cel-go")

  static func read(_ path: String) throws -> String {
    try String(contentsOf: celGo.appendingPathComponent(path), encoding: .utf8)
  }

  /// A suite, its expression and how cel-go configures the compiler for it.
  struct SuiteCase: CustomTestStringConvertible, Sendable {
    var name: String
    /// A policy or `.cel` file relative to `third_party/cel-go`, or a raw expression.
    var expression: String
    var testSuite: String
    var configs: [String] = []
    /// Options applied before the configs, such as the types they refer to.
    var typeOptions: [Environment.Option] = []
    /// Options applied after the configs, such as function implementations.
    var options: [Environment.Option] = []
    var tagVisitor: any PolicyTagVisitor = DefaultPolicyTagVisitor()
    var metadataOptions: [@Sendable ([String: any Sendable]) -> [Environment.Option]] = []
    /// The number of tests in the suite, so a suite that silently loses tests fails.
    var testCount: Int
    var testDescription: String { name }
  }

  static func policySuite(
    _ name: String, testCount: Int, typeOptions: [Environment.Option] = [], options: [Environment.Option] = [],
    tagVisitor: any PolicyTagVisitor = DefaultPolicyTagVisitor()
  ) -> SuiteCase {
    SuiteCase(
      name: name, expression: "policy/testdata/\(name)/policy.yaml",
      testSuite: "policy/testdata/\(name)/tests.yaml", configs: ["policy/testdata/\(name)/config.yaml"],
      typeOptions: typeOptions, options: options, tagVisitor: tagVisitor, testCount: testCount)
  }

  static let suites: [SuiteCase] = [
    // tools/celtest/test_runner_test.go setupTests.
    policySuite("k8s", testCount: 1, tagVisitor: K8sTagVisitor()),
    policySuite("restricted_destinations", testCount: 4, options: [CELGoTestFixtures.locationCode]),
    SuiteCase(
      name: "custom_policy", expression: "tools/celtest/testdata/custom_policy.celpolicy",
      testSuite: "tools/celtest/testdata/custom_policy_tests.yaml",
      tagVisitor: VariableTypesTagVisitor(), metadataOptions: [parsePolicyVariables], testCount: 3),
    SuiteCase(
      name: "raw_expr_file", expression: "tools/celtest/testdata/raw_expr.cel",
      testSuite: "tools/celtest/testdata/raw_expr_tests.yaml", configs: ["tools/celtest/testdata/config.yaml"],
      options: [CELGoTestFixtures.fn], testCount: 6),
    SuiteCase(
      name: "raw_expr", expression: "a || i + fn(j) == 42",
      testSuite: "tools/celtest/testdata/raw_expr_tests.yaml", configs: ["tools/celtest/testdata/config.yaml"],
      options: [CELGoTestFixtures.fn], testCount: 6),
    // The cel_go_test targets.
    policySuite("pb", testCount: 2, typeOptions: [CELGoTestFixtures.types]),
    policySuite("nested_rules_variable_shadowing", testCount: 3),
    policySuite("nested_rules_unconditional_chaining", testCount: 3),
    policySuite("nested_rules_unconditional_chaining_optional", testCount: 4),
    policySuite("nested_rules_unwrap_rewrap", testCount: 3),
    policySuite("variable_type_propagation", testCount: 1),
    // The suites cel-go runs through policy/compiler_test.go.
    policySuite("unnest", testCount: 5),
    policySuite("limits", testCount: 4),
    policySuite("agent_tool_execution_governance", testCount: 4, options: CELGoTestFixtures.agentFunctions),
    // The restricted_destinations config split into a base config and a partial config
    // (celtest `--base_config_path`).
    SuiteCase(
      name: "restricted_destinations_base_config",
      expression: "policy/testdata/restricted_destinations/policy.yaml",
      testSuite: "policy/testdata/restricted_destinations/tests.yaml",
      configs: [
        "policy/testdata/restricted_destinations/base_config.yaml",
        "policy/testdata/restricted_destinations/partial_config.yaml",
      ],
      options: [CELGoTestFixtures.locationCode], testCount: 4),
  ]

  /// Builds the compiler and runner for a suite as cel-go's `TriggerTests` does, with partial
  /// evaluation.
  static func run(_ tc: SuiteCase) throws -> [TestResult] {
    var options = tc.typeOptions
    for config in tc.configs {
      options.append(.environmentConfig(try EnvironmentConfig(yaml: try read(config))))
    }
    options += tc.options
    var compiler = try TestCompiler(options: options, policyParser: PolicyParser(tagVisitor: tc.tagVisitor))
    compiler.policyMetadataOptions = tc.metadataOptions
    var expressions: [CheckedExpression] = []
    var policies: [CompiledPolicy] = []
    switch TestCompiler.kind(of: tc.expression) {
    case .policyFile:
      policies.append(try compiler.compile(policyFile: try read(tc.expression), path: tc.expression))
    case .celFile:
      expressions.append(try compiler.compile(celFile: try read(tc.expression), path: tc.expression))
    case .raw:
      expressions.append(try compiler.compile(expression: tc.expression))
    }
    let runner = try TestRunner(compiler: compiler, expressions: expressions, policies: policies)
    return runner.run(try TestSuite(yaml: try read(tc.testSuite)))
  }

  @Test(arguments: suites)
  func suite(_ tc: SuiteCase) throws {
    let results = try Self.run(tc)
    #expect(results.count == tc.testCount)
    for result in results {
      #expect(result.passed, "\(result.failureDescription ?? "")")
    }
  }

  /// Every `policy/testdata` suite is covered by `suites`.
  @Test func everyPolicySuiteRuns() throws {
    let dir = Self.celGo.appendingPathComponent("policy/testdata")
    let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter {
      FileManager.default.fileExists(atPath: dir.appendingPathComponent("\($0)/tests.yaml").path)
    }
    let covered = Set(Self.suites.map(\.testSuite))
    for name in names.sorted() {
      #expect(covered.contains("policy/testdata/\(name)/tests.yaml"), "\(name)")
    }
  }

  /// cel-go `TestCustomTestSuiteParser`: a suite built in code.
  @Test func suiteBuiltInCode() throws {
    let compiler = try TestCompiler(options: [
      .environmentConfig(try EnvironmentConfig(yaml: try Self.read("tools/celtest/testdata/config.yaml"))),
      CELGoTestFixtures.fn,
    ])
    let runner = try TestRunner(
      compiler: compiler, expressions: [try compiler.compile(expression: "a || i + fn(j) == 42")])
    let suite = TestSuite(
      description: "sample test suite",
      sections: [
        TestSection(
          name: "sample test section",
          tests: [
            TestCase(
              name: "sample test case",
              input: [
                "i": TestInputValue(value: .int(21)), "j": TestInputValue(value: .int(42)),
                "a": TestInputValue(value: .bool(false)),
              ],
              output: TestOutput(value: .bool(true)))
          ])
      ])
    let results = runner.run(suite)
    #expect(results.map(\.name) == ["sample test section/sample test case"])
    #expect(results.allSatisfy { $0.passed })
  }

  // MARK: - Matchers

  static func rawRunner(_ expression: String) throws -> TestRunner {
    let compiler = try TestCompiler(options: [
      .environmentConfig(try EnvironmentConfig(yaml: try Self.read("tools/celtest/testdata/config.yaml"))),
      CELGoTestFixtures.fn,
    ])
    return try TestRunner(compiler: compiler, expressions: [try compiler.compile(expression: expression)])
  }

  static func outcome(_ expression: String, _ suiteYAML: String) throws -> [TestResult] {
    try rawRunner(expression).run(try TestSuite(yaml: suiteYAML))
  }

  @Test func valueMismatchFails() throws {
    let results = try Self.outcome(
      "i + 1",
      """
      section:
        - name: s
          tests:
            - name: wrong
              input:
                i:
                  value: 1
              output:
                value: 3
            - name: right
              input:
                i:
                  value: 1
              output:
                expr: "1 + 1"
      """)
    #expect(results.map(\.passed) == [false, true])
    #expect(results[0].failureDescription == "test: s/wrong \n wanted: simple value 3 \n failed: policy eval got 2")
  }

  @Test func errorSet() throws {
    let results = try Self.outcome(
      "i / j == 1",
      """
      section:
        - name: s
          tests:
            - name: division by zero
              input:
                i:
                  value: 1
                j:
                  value: 0
                a:
                  value: false
              output:
                error_set:
                  - "no such overload"
                  - "division by zero"
            - name: no error
              input:
                i:
                  value: 1
                j:
                  value: 1
                a:
                  value: false
              output:
                error_set:
                  - "division by zero"
      """)
    #expect(results.map(\.passed) == [true, false])
    #expect(results[1].failureDescription == "test: s/no error \n wanted: error [division by zero] \n failed: <nil>")
  }

  @Test func unknownSet() throws {
    let results = try Self.outcome(
      "a || i + fn(j) == 42",
      """
      section:
        - name: s
          tests:
            - name: right ids
              input:
                j:
                  value: 42
                a:
                  value: false
              output:
                unknown_set: [2]
            - name: wrong ids
              input:
                j:
                  value: 42
                a:
                  value: false
              output:
                unknown_set: [1]
      """)
    #expect(results.map(\.passed) == [true, false])
  }

  @Test func inputAndContextAreExclusive() throws {
    let results = try Self.outcome(
      "a",
      """
      section:
        - name: s
          tests:
            - name: both
              input:
                a:
                  value: true
              context_expr: "{}"
              output:
                value: true
      """)
    #expect(results.map(\.passed) == [false])
    #expect(
      results[0].failureDescription?.contains("only one of input and input_context can be provided at a time") == true)
  }

  // MARK: - cel-swift policy test

  /// The suites the command can run: all but the one needing a custom tag visitor and metadata
  /// options. A stored property, since Swift 6.0 crashes on a closure inside `@Test(arguments:)`.
  static let commandSuites = suites.filter { $0.metadataOptions.isEmpty }

  @Test(arguments: commandSuites)
  func command(_ tc: SuiteCase) throws {
    var command = PolicyTestCommand()
    let isPath = TestCompiler.kind(of: tc.expression) != .raw
    command.celExpression = isPath ? Self.celGo.appendingPathComponent(tc.expression).path : tc.expression
    command.testSuitePath = Self.celGo.appendingPathComponent(tc.testSuite).path
    if tc.configs.count == 2 {
      command.baseConfigPath = Self.celGo.appendingPathComponent(tc.configs[0]).path
      command.configPath = Self.celGo.appendingPathComponent(tc.configs[1]).path
    } else if let config = tc.configs.first {
      command.configPath = Self.celGo.appendingPathComponent(config).path
    }
    command.celGoTestFixtures = true
    command.k8sTags = tc.tagVisitor is K8sTagVisitor
    command.verbose = true
    var lines: [String] = []
    let code = command.run { lines.append($0) }
    #expect(code == 0, "\(lines.joined(separator: "\n"))")
    #expect(lines.filter { $0.hasPrefix("--- PASS: ") }.count == tc.testCount)
    #expect(lines.last == "PASS: \(tc.testCount) tests")
  }

  @Test func commandArguments() throws {
    let command = try PolicyTestCommand(arguments: [
      "--cel-expr", "policy.yaml", "--test_suite_path=tests.yaml", "--config", "c.yaml", "--base-config=b.yaml",
      "--cel-go-test-fixtures", "--k8s-tags",
    ])
    #expect(command.celExpression == "policy.yaml")
    #expect(command.testSuitePath == "tests.yaml")
    #expect(command.configPath == "c.yaml")
    #expect(command.baseConfigPath == "b.yaml")
    #expect(command.celGoTestFixtures && command.k8sTags && !command.verbose)
    #expect(throws: CommandLineError.self) { try PolicyTestCommand(arguments: ["--cel-expr", "x"]) }
    #expect(throws: CommandLineError.self) { try PolicyTestCommand(arguments: ["--bogus"]) }
  }

  @Test func commandReportsFailures() throws {
    var lines: [String] = []
    let command = try PolicyTestCommand(arguments: [
      "--cel-expr", "a || i + fn(j) == 43", "--cel-go-test-fixtures",
      "--config", Self.celGo.appendingPathComponent("tools/celtest/testdata/config.yaml").path,
      "--test-suite", Self.celGo.appendingPathComponent("tools/celtest/testdata/raw_expr_tests.yaml").path,
    ])
    let code = command.run { lines.append($0) }
    #expect(code == 1)
    #expect(lines.contains("--- FAIL: valid/true"))
    #expect(lines.last == "FAIL: 2 of 6 tests failed")
  }

  @Test func commandLoadErrors() throws {
    var lines: [String] = []
    let command = try PolicyTestCommand(arguments: [
      "--cel-expr", "missing.yaml", "--test-suite", "missing_tests.yaml",
    ])
    #expect(command.run { lines.append($0) } == 2)
    #expect(lines.first?.hasPrefix("error: failed to read file \"missing.yaml\"") == true)
  }
}

/// The custom policy tag of tools/celtest/test_runner_test.go (`customTagHandler`): `variable_types`
/// records each variable's type name in the policy metadata.
struct VariableTypesTagVisitor: PolicyTagVisitor {
  func visitPolicyTag(
    _ tagName: String, id: Int64, node: YAMLNode, policy: inout Policy, context: inout PolicyParserContext
  ) {
    guard tagName == "variable_types" else {
      context.reportError(atID: id, "unsupported policy tag: \(tagName)")
      return
    }
    guard case .list(let items)? = try? node.decodeValue() else {
      context.reportError(atID: id, "invalid yaml variable_types node: \(node.value)")
      return
    }
    for item in items {
      guard case .map(let entries) = item else {
        continue
      }
      var name = ""
      var type = ""
      for entry in entries {
        switch (entry.key, entry.value) {
        case (.string("variable_name"), .string(let v)): name = v
        case (.string("variable_type"), .string(let v)): type = v
        default: break
        }
      }
      policy.setMetadata(type, forKey: name)
    }
  }
}

/// cel-go `ParsePolicyVariables`: declares each metadata entry as a variable of the named type.
@Sendable func parsePolicyVariables(_ metadata: [String: any Sendable]) -> [Environment.Option] {
  var variables: [VariableDecl] = []
  for (name, type) in metadata {
    switch type as? String {
    case "int": variables.append(VariableDecl(name: name, type: .int))
    case "string": variables.append(VariableDecl(name: name, type: .string))
    default: variables.append(VariableDecl(name: name, type: .unknown))
    }
  }
  return [.variables(variables)]
}

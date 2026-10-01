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

// `cel-swift policy test`: the flags and flow of cel-go tools/celtest/test_runner.go
// (TestRunnerOptionsFromFlags, TriggerTests) with tools/compiler/compiler.go (EnvironmentFile,
// FileExpression, RawExpression).
//
// Not ported: textproto test suites, checked-expression files, file descriptor sets and coverage.
// Types come from the fixtures (`--cel-go-test-fixtures`) instead of descriptor sets.

import CEL
import CELPolicy
import CELTest
import Foundation

/// Runs a `tests.yaml` suite against a policy, a `.cel` file or an expression.
package struct PolicyTestCommand {
  package static let usage = """
    USAGE: cel-swift policy test --cel-expr <policy.yaml|expr.cel|expression> --test-suite <tests.yaml>
                                 [--base-config <config.yaml>] [--config <config.yaml>]
                                 [--cel-go-test-fixtures] [--k8s-tags] [--verbose]

    Runs every test of the suite and reports the failures, as cel-go's celtest does.

    OPTIONS:
      --cel-expr <value>       A .celpolicy or .yaml policy, a .cel file, or a CEL expression.
      --test-suite <path>      The tests.yaml suite.
      --base-config <path>     An environment config applied before --config.
      --config <path>          The environment config.
      --cel-go-test-fixtures   Add the functions and test message types cel-go's test runners
                               bind (locationCode, hasCreditCard, hasEmailOrPhone, fn,
                               google.expr.proto3.test.TestAllTypes, ...).
      --k8s-tags               Parse policies with the Kubernetes tag handler cel-go tests with
                               (kind, metadata, spec, validations, ...).
      --verbose                Also print the passing tests.
    """

  package var celExpression = ""
  package var testSuitePath = ""
  package var baseConfigPath = ""
  package var configPath = ""
  package var celGoTestFixtures = false
  package var k8sTags = false
  package var verbose = false

  package init() {}

  /// Parses the arguments after `policy test`.
  package init(arguments: [String]) throws(CommandLineError) {
    var i = 0
    func value(_ flag: String) throws(CommandLineError) -> String {
      i += 1
      guard i < arguments.count else {
        throw CommandLineError("missing value for \(flag)")
      }
      return arguments[i]
    }
    while i < arguments.count {
      var arg = arguments[i]
      var inline: String?
      if let eq = arg.firstIndex(of: "="), arg.hasPrefix("--") {
        inline = String(arg[arg.index(after: eq)...])
        arg = String(arg[..<eq])
      }
      func flagValue() throws(CommandLineError) -> String {
        if let inline {
          return inline
        }
        return try value(arg)
      }
      switch arg {
      case "--cel-expr", "--cel_expr": celExpression = try flagValue()
      case "--test-suite", "--test_suite_path": testSuitePath = try flagValue()
      case "--base-config", "--base_config_path": baseConfigPath = try flagValue()
      case "--config", "--config_path": configPath = try flagValue()
      case "--cel-go-test-fixtures": celGoTestFixtures = true
      case "--k8s-tags": k8sTags = true
      case "--verbose", "-v": verbose = true
      default: throw CommandLineError("unknown argument: \(arguments[i])")
      }
      i += 1
    }
    if celExpression.isEmpty {
      throw CommandLineError("--cel-expr is required")
    }
    if testSuitePath.isEmpty {
      throw CommandLineError("--test-suite is required")
    }
  }

  /// Runs the suite, writing the report to `output`.
  ///
  /// - Returns: The exit code: 0 when every test passed, 1 when a test failed, 2 when the
  ///   expression or the suite could not be loaded.
  package func run(output: (String) -> Void) -> Int32 {
    do {
      let results = try results()
      var failed = 0
      for result in results {
        if let failure = result.failureDescription {
          failed += 1
          output("--- FAIL: \(result.name)")
          output(failure)
        } else if verbose {
          output("--- PASS: \(result.name)")
        }
      }
      if failed > 0 {
        output("FAIL: \(failed) of \(results.count) tests failed")
        return 1
      }
      output("PASS: \(results.count) tests")
      return 0
    } catch {
      output("error: \(error)")
      return 2
    }
  }

  /// Compiles the expression and runs every test (cel-go `TriggerTests`).
  package func results() throws -> [TestResult] {
    var options: [Environment.Option] = []
    if celGoTestFixtures {
      // Types first: the configs may declare variables of the test message types.
      options.append(CELGoTestFixtures.types)
    }
    for path in [baseConfigPath, configPath] where !path.isEmpty {
      options.append(.environmentConfig(try Self.environmentConfig(path)))
    }
    if celGoTestFixtures {
      options += [CELGoTestFixtures.locationCode, CELGoTestFixtures.fn] + CELGoTestFixtures.agentFunctions
    }
    var parser = PolicyParser()
    if k8sTags {
      parser.tagVisitor = K8sTagVisitor()
    }
    let compiler = try TestCompiler(options: options, policyParser: parser)

    var expressions: [CheckedExpression] = []
    var policies: [CompiledPolicy] = []
    switch TestCompiler.kind(of: celExpression) {
    case .celFile:
      expressions.append(try compiler.compile(celFile: try Self.read(celExpression), path: celExpression))
    case .policyFile:
      policies.append(try compiler.compile(policyFile: try Self.read(celExpression), path: celExpression))
    case .raw:
      if Self.hasFileExtension(celExpression) {
        throw CommandLineError(
          "unsupported --cel-expr file \(celExpression): wanted .cel, .celpolicy or .yaml")
      }
      expressions.append(try compiler.compile(expression: celExpression))
    }

    guard testSuitePath.hasSuffix(".yaml") else {
      throw CommandLineError("unsupported test suite \(testSuitePath): only .yaml suites are supported")
    }
    let suite = try TestSuite(yaml: try Self.read(testSuitePath))
    let runner = try TestRunner(compiler: compiler, expressions: expressions, policies: policies)
    let results = runner.run(suite)
    if results.isEmpty {
      throw CommandLineError("no tests found")
    }
    return results
  }

  static func environmentConfig(_ path: String) throws -> EnvironmentConfig {
    guard path.hasSuffix(".yaml") else {
      throw CommandLineError("unsupported environment config \(path): only .yaml configs are supported")
    }
    do {
      return try EnvironmentConfig(yaml: try read(path))
    } catch let error as CommandLineError {
      throw error
    } catch {
      throw CommandLineError("yaml.Unmarshal failed to map CEL environment: \(error)")
    }
  }

  /// Whether the argument looks like a file cel-go's compiler would not take as an expression
  /// (cel-go `InferFileFormat` other than `Unspecified`).
  static func hasFileExtension(_ argument: String) -> Bool {
    [".textproto", ".binarypb", ".fds", ".pb"].contains { argument.hasSuffix($0) }
  }

  static func read(_ path: String) throws(CommandLineError) -> String {
    do {
      return try String(contentsOfFile: path, encoding: .utf8)
    } catch {
      throw CommandLineError("failed to read file \"\(path)\": \(error.localizedDescription)")
    }
  }
}

/// A usage or input error of the command-line tool.
package struct CommandLineError: Error, CustomStringConvertible {
  package var description: String

  package init(_ description: String) {
    self.description = description
  }
}

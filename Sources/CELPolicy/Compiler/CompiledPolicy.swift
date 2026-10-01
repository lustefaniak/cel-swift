// Copyright 2024 Google LLC
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

// The public entry point of cel-go policy/compiler.go (`Compile`, `MaxNestedExpressions`) and
// policy/composer.go (`ExpressionUnnestHeight`).
//
// cel-go expects the caller's environment to include `cel.OptionalTypes()` and `ext.Bindings()`;
// the composed expression uses `optional.*` and `cel.@block`. Here the compiler adds both (as
// cel-go's `tools/compiler` does) and returns the environment it compiled with, so programs are
// always created from an environment that can evaluate the composed expression.

import CEL
import CELExtensions

/// Compiles parsed policies into single CEL expressions.
///
/// ```swift
/// let policy = try PolicyParser().parse(PolicySource(yaml, description: "policy.yaml"))
/// let env = try Environment(.environmentConfig(try EnvironmentConfig(yaml: configYAML)))
/// let compiled = try PolicyCompiler().compile(policy, environment: env)
/// let result = try compiled.program().evaluate(["x": 1])
/// ```
public struct PolicyCompiler: Sendable {
  /// The maximum number of variables and nested rules in a policy (cel-go
  /// `MaxNestedExpressions`); 100 by default.
  public var maxNestedExpressions: Int
  /// The expression height above which the composer moves sub-expressions into `cel.@block`
  /// slots (cel-go `ExpressionUnnestHeight`); 25 by default.
  public var expressionUnnestHeight: Int

  package var compileMatchOutput: CompileMatchOutput?

  /// Creates a compiler.
  ///
  /// - Parameters:
  ///   - maxNestedExpressions: The maximum number of variables and nested rules.
  ///   - expressionUnnestHeight: The height above which sub-expressions are unnested.
  public init(maxNestedExpressions: Int = 100, expressionUnnestHeight: Int = 25) {
    self.maxNestedExpressions = maxNestedExpressions
    self.expressionUnnestHeight = expressionUnnestHeight
  }

  /// Compiles a policy into a single checked expression (cel-go `policy.Compile`).
  ///
  /// - Parameters:
  ///   - policy: The parsed policy.
  ///   - environment: The environment declaring the variables and functions the policy uses.
  /// - Returns: The composed expression and the environment to create programs from.
  /// - Throws: ``PolicyError`` with every compile error, positioned in the policy file.
  public func compile(_ policy: Policy, environment: Environment) throws(PolicyError) -> CompiledPolicy {
    let env: Environment
    do {
      env = try environment.withPolicySupport()
    } catch {
      var errors = PolicyError(source: policy.source)
      errors.report(
        id: policy.name.id, location: policy.sourceInfo.startLocation(policy.name.id),
        message: "error configuring environment: \(error)")
      throw errors
    }
    var options = PolicyCompilerOptions(maxNestedExpressions: maxNestedExpressions)
    options.compileMatchOutput = compileMatchOutput
    let (rule, errors) = compileRule(policy, env: env, options: options)
    guard let rule, errors.isEmpty else {
      throw errors
    }
    let composer: RuleComposer
    do {
      composer = try RuleComposer(env: env, exprUnnestHeight: expressionUnnestHeight)
    } catch {
      var errors = PolicyError(source: policy.source)
      errors.report(id: 0, location: .none, message: "\(error)")
      throw errors
    }
    let (ast, composeErrors) = composer.compose(rule)
    guard let ast else {
      var result = PolicyError(source: policy.source)
      result.errors = result.errors.appending(composeErrors.errors)
      throw result
    }
    return CompiledPolicy(
      expression: CheckedExpression(ast: ast, source: policy.source), environment: env)
  }
}

/// A policy compiled into one CEL expression, with the environment that evaluates it.
public struct CompiledPolicy: Sendable {
  /// The composed, type-checked expression.
  public let expression: CheckedExpression
  /// The environment the policy was compiled in: the caller's environment with optional types
  /// and the bindings library.
  public let environment: Environment

  /// The type the policy evaluates to: the output type, `optional_type(T)` when no match may
  /// apply, or `list(T)` for aggregate rules.
  public var outputType: CELType { expression.outputType }

  /// Creates a program evaluating the policy.
  ///
  /// - Parameter options: Evaluation options such as cost limits and state tracking.
  /// - Throws: `CompileError` when the expression cannot be planned, for example because a
  ///   declared function has no implementation.
  public func program(options: [Program.Option] = []) throws(CompileError) -> Program {
    try environment.program(expression, options: options)
  }
}

extension Environment {
  /// The environment with optional types and the bindings library (`cel.@block`), which
  /// composed policies use (cel-go `tools/compiler` `extensionOpt`).
  package func withPolicySupport() throws(DeclarationError) -> Environment {
    try extending(options: [.library(.optionalTypes()), .library(.bindings())])
  }
}

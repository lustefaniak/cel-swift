// Copyright 2023 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
// Ported from cel-go cel/validator.go. cel-go's `ASTValidator` is an open interface over the
// navigable AST; the AST is not public here, so validators are values with a package-level
// implementation and the built-in ones are exposed as factories. The validator configuration
// (`ValidatorConfig`) has one key in cel-go, the homogeneous literal exemptions, which the
// environment collects from its libraries directly.

import CELRegex

/// A check run on every expression an environment type-checks, reporting extra issues
/// (cel-go `ASTValidator`).
///
/// Add validators with ``Environment/Option/validators(_:)-([ExpressionValidator])``. Validators are singletons by
/// ``name``: adding one with the name of an existing validator keeps the first.
public struct ExpressionValidator: Sendable {
  /// The unique validator name, such as `cel.validator.duration`.
  public let name: String

  /// The configuration as stored in environment config files: an integer `limit` for the
  /// nesting and size limits.
  public let limit: Int?

  package let validate: @Sendable (_ context: ValidationContext, _ issues: inout CELErrors) -> Void

  package init(
    name: String, limit: Int? = nil,
    validate: @escaping @Sendable (_ context: ValidationContext, _ issues: inout CELErrors) -> Void
  ) {
    self.name = name
    self.limit = limit
    self.validate = validate
  }

  /// Rejects `duration("...")` calls whose literal argument is not a valid duration
  /// (cel-go `ValidateDurationLiterals`).
  public static let durationLiterals = formatValidator(Overloads.typeConvertDuration, argument: 0, check: evaluateCall)

  /// Rejects `timestamp("...")` calls whose literal argument is not a valid timestamp
  /// (cel-go `ValidateTimestampLiterals`).
  public static let timestampLiterals = formatValidator(
    Overloads.typeConvertTimestamp, argument: 0, check: evaluateCall)

  /// Rejects `matches` calls whose literal pattern is not a valid RE2 regular expression
  /// (cel-go `ValidateRegexLiterals`).
  public static let regexLiterals = formatValidator(Overloads.matches, argument: 0) { _, _, arg in
    guard case .literal(.string(let pattern)) = arg.kind else {
      return true
    }
    return (try? Regexp.compile(pattern)) != nil
  }

  /// Rejects list and map literals whose elements have different types, except as arguments of
  /// functions that expect mixed lists such as `format` (cel-go
  /// `ValidateHomogeneousAggregateLiterals`).
  public static let homogeneousAggregateLiterals = ExpressionValidator(
    name: "cel.validator.homogeneous_literals", validate: validateHomogeneousLiterals)

  /// Rejects expressions with more than `limit` nested comprehensions, not counting
  /// comprehensions over empty lists such as `cel.bind` (cel-go
  /// `ValidateComprehensionNestingLimit`).
  public static func comprehensionNestingLimit(_ limit: Int) -> ExpressionValidator {
    ExpressionValidator(name: "cel.validator.comprehension_nesting_limit", limit: limit) { context, issues in
      let comprehensions = context.root.matchDescendants { $0.expr.asComprehension != nil }
      if comprehensions.count <= limit {
        return
      }
      for comprehension in comprehensions {
        var count = 0
        var node: NavigableExpr? = comprehension
        while let e = node {
          if e.expr.asComprehension != nil && !isEmptyRangeComprehension(e.expr) {
            count += 1
            if count > limit {
              context.report(&issues, id: comprehension.id, "comprehension exceeds nesting limit")
              break
            }
          }
          node = e.parent
        }
      }
    }
  }

  /// Rejects expressions with more than `limit` nested `cel.bind` calls (cel-go
  /// `ValidateBindNestingLimit`).
  public static func bindNestingLimit(_ limit: Int) -> ExpressionValidator {
    ExpressionValidator(name: "cel.validator.bind_nesting_limit", limit: limit) { context, issues in
      let binds = context.root.matchDescendants { isCelBind($0.expr) }
      if binds.count <= limit {
        return
      }
      for bind in binds {
        var count = 0
        var node: NavigableExpr? = bind
        while let e = node {
          if isCelBind(e.expr) {
            count += 1
            if count > limit {
              context.report(&issues, id: bind.id, "cel.bind exceeds nesting limit")
              break
            }
          }
          node = e.parent
        }
      }
    }
  }

  /// Rejects literal regular expressions whose compiled program has more than `limit`
  /// instructions (cel-go `ValidateRegexProgramSizeLimit`).
  public static func regexProgramSizeLimit(_ limit: Int) -> ExpressionValidator {
    ExpressionValidator(name: "cel.validator.regex_program_size_limit", limit: limit) { context, issues in
      if limit <= 0 {
        return
      }
      for call in context.root.matchDescendants({ $0.expr.asCall != nil }) {
        guard let c = call.expr.asCall, isRegexFunctionName(c.function) else {
          continue
        }
        let index = (c.function == Overloads.matches && c.target != nil) ? 0 : 1
        guard c.args.count > index, case .literal(.string(let pattern)) = c.args[index].kind else {
          continue
        }
        guard let size = try? Regexp.programSize(pattern) else {
          continue
        }
        if size > limit {
          context.report(&issues, id: c.args[index].id, "regex program size \(size) exceeds limit of \(limit)")
        }
      }
    }
  }

  /// The duration, timestamp, regular expression and homogeneous literal validators (cel-go
  /// `ExtendedValidations`).
  public static let extended: [ExpressionValidator] = [
    durationLiterals, timestampLiterals, regexLiterals, homogeneousAggregateLiterals,
  ]

  /// The validator with a name used in environment config files, such as
  /// `cel.validator.duration` or `cel.validator.comprehension_nesting_limit` (with `limit`).
  ///
  /// - Returns: The validator, or `nil` when the name is unknown or a limit is missing.
  public static func named(_ name: String, limit: Int? = nil) -> ExpressionValidator? {
    switch name {
    case durationLiterals.name: return durationLiterals
    case timestampLiterals.name: return timestampLiterals
    case regexLiterals.name: return regexLiterals
    case homogeneousAggregateLiterals.name: return homogeneousAggregateLiterals
    case "cel.validator.comprehension_nesting_limit": return limit.map(comprehensionNestingLimit)
    case "cel.validator.bind_nesting_limit": return limit.map(bindNestingLimit)
    case "cel.validator.regex_program_size_limit": return limit.map(regexProgramSizeLimit)
    default: return nil
    }
  }

  private static func formatValidator(
    _ function: String, argument: Int,
    check: @escaping @Sendable (Environment, Expr, Expr) -> Bool
  ) -> ExpressionValidator {
    ExpressionValidator(name: "cel.validator.\(function)") { context, issues in
      for call in context.root.matchDescendants(NavigableExpr.functionMatcher(function)) {
        guard let c = call.expr.asCall, c.args.count > argument else {
          continue
        }
        let arg = c.args[argument]
        guard case .literal = arg.kind else {
          continue
        }
        if !check(context.environment, call.expr, arg) {
          context.report(&issues, id: arg.id, "invalid \(function) argument")
        }
      }
    }
  }

  /// Evaluates a call with literal arguments, failing when it produces an error (cel-go
  /// `evalCall`).
  private static let evaluateCall: @Sendable (Environment, Expr, Expr) -> Bool = { env, call, _ in
    let ast = AST(expr: call, sourceInfo: SourceInfo(source: nil))
    guard let program = try? env.makeProgram(ast, source: TextSource(""), options: []) else {
      return false
    }
    return !program.run(EmptyActivation()).value.isError
  }
}

/// What a validator sees: the environment and the checked expression.
package struct ValidationContext {
  package let environment: Environment
  package let ast: AST
  package let root: NavigableExpr
  package let homogeneousLiteralExemptFunctions: [String]

  /// Reports an issue at the start location of an expression id (cel-go `ReportErrorAtID`).
  package func report(_ issues: inout CELErrors, id: Int64, _ message: String) {
    issues.reportError(exprID: id, at: ast.sourceInfo.startLocation(id), message)
  }
}

extension Environment {
  /// Runs the environment's validators on a checked expression.
  func validate(_ expression: CheckedExpression) throws(CompileError) {
    let validators = configuration.validators
    if validators.isEmpty {
      return
    }
    let context = ValidationContext(
      environment: self, ast: expression.ast, root: NavigableExpr(root: expression.ast.expr),
      homogeneousLiteralExemptFunctions: configuration.homogeneousLiteralExemptFunctions)
    var issues = CELErrors(source: expression.source)
    for validator in validators {
      validator.validate(context, &issues)
    }
    if !issues.isEmpty {
      throw CompileError(issues)
    }
  }
}

private func validateHomogeneousLiterals(_ context: ValidationContext, _ issues: inout CELErrors) {
  let ast = context.ast
  let exempt = context.homogeneousLiteralExemptFunctions
  func inExemptFunction(_ e: NavigableExpr) -> Bool {
    var parent = e.parent
    while let p = parent {
      if let call = p.expr.asCall, exempt.contains(call.function) {
        return true
      }
      parent = p.parent
    }
    return false
  }
  func mismatch(_ id: Int64, _ expected: CELType, _ actual: CELType) {
    context.report(
      &issues, id: id,
      "expected type '\(expected.checkerDescription)' but found '\(actual.checkerDescription)'")
  }
  for listExpr in context.root.matchDescendants({ $0.expr.asList != nil }) {
    guard let list = listExpr.expr.asList, !inExemptFunction(listExpr) else {
      continue
    }
    var elemType: CELType?
    for (i, e) in list.elements.enumerated() {
      var et = ast.type(of: e.id)
      if list.isOptional(Int32(i)), let inner = et.parameters.first {
        et = inner
      }
      guard let expected = elemType else {
        elemType = et
        continue
      }
      if !expected.isEquivalentType(et) {
        mismatch(e.id, expected, et)
        break
      }
    }
  }
  for mapExpr in context.root.matchDescendants({ $0.expr.asMap != nil }) {
    guard let map = mapExpr.expr.asMap, !inExemptFunction(mapExpr) else {
      continue
    }
    var types: (key: CELType, value: CELType)?
    for entry in map.entries {
      let kt = ast.type(of: entry.key.id)
      var vt = ast.type(of: entry.value.id)
      if entry.isOptional, let inner = vt.parameters.first {
        vt = inner
      }
      guard let expected = types else {
        types = (kt, vt)
        continue
      }
      if !expected.key.isEquivalentType(kt) {
        mismatch(entry.key.id, expected.key, kt)
      }
      if !expected.value.isEquivalentType(vt) {
        mismatch(entry.value.id, expected.value, vt)
      }
    }
  }
}

private func isEmptyRangeComprehension(_ e: Expr) -> Bool {
  guard let c = e.asComprehension, let list = c.iterRange.asList else {
    return false
  }
  return list.elements.isEmpty
}

private func isCelBind(_ e: Expr) -> Bool {
  guard isEmptyRangeComprehension(e), let c = e.asComprehension else {
    return false
  }
  guard case .literal(.bool(false)) = c.loopCondition.kind, c.loopStep.asIdent == c.accuVar else {
    return false
  }
  return c.iterVar == "#unused"
}

private func isRegexFunctionName(_ function: String) -> Bool {
  function == Overloads.matches || function == "regex.extract" || function == "regex.extractAll"
    || function == "regex.replace"
}

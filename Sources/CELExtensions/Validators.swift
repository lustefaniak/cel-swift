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
// Ported from cel-go ext/formatting.go and ext/formatting_v2.go (stringFormatValidator,
// stringFormatChecker, matchConstantFormatStringWithListLiteralArgs, getErrorExprID) and
// ext/network.go (networkFormatValidator, checkIP, checkCIDR): the AST validators the strings and
// network libraries install.

import CEL

enum FormatValidator {
  /// The `string.format` validator: parses literal format strings and checks each clause against
  /// the checked type of the matching element of a literal argument list.
  static func make(maxPrecision: Int, v2: Bool) -> ExpressionValidator {
    ExpressionValidator(name: "cel.validator.string_format") { context, issues in
      let ast = context.ast
      let calls = context.root.matchDescendants { e in matchesFormatCall(e.expr, ast) }
      for e in calls {
        guard let call = e.expr.asCall, let target = call.target,
          case .literal(.string(let format)) = target.kind, let list = call.args.first?.asList
        else { continue }
        let args = list.elements
        var argsRequested = 0
        let result = parseFormatString(
          format, argumentCount: args.count, maxPrecision: maxPrecision,
          requestArgument: { _ in
            argsRequested += 1
            return nil
          },
          formatArgument: { index, clause in
            check(clause, args[index], ast, v2: v2).map { .failure($0) } ?? .success("")
          })
        if case .failure(let err) = result {
          context.report(&issues, id: err.exprID ?? e.id, err.message)
          continue
        }
        if args.count > argsRequested {
          context.report(
            &issues, id: e.id,
            "too many arguments supplied to string.format (expected \(argsRequested), got \(args.count))")
        }
      }
    }
  }

  /// Port of `matchConstantFormatStringWithListLiteralArgs`.
  private static func matchesFormatCall(_ e: Expr, _ ast: AST) -> Bool {
    guard let call = e.asCall, call.isMemberFunction, call.function == "format" else {
      return false
    }
    let overloads = ast.overloadIDs(of: e.id)
    if !overloads.isEmpty && !overloads.contains("string_format") {
      return false
    }
    guard let target = call.target, case .literal(.string) = target.kind else {
      return false
    }
    return call.args.count == 1 && call.args[0].asList != nil
  }

  /// Port of `verifyTypeOneOf`: dyn passes, otherwise only the kind is compared.
  private static func verify(_ id: Int64, _ ast: AST, _ kinds: [CELType.Kind]) -> Bool {
    let t = ast.type(of: id)
    if t == .dyn {
      return true
    }
    return kinds.contains(t.kind)
  }

  /// Port of `verifyString`: the first offending sub-expression id, recursing into list and map
  /// literals.
  private static func verifyString(_ sub: Expr, _ ast: AST) -> Int64? {
    let valid: [CELType.Kind] = [
      .list, .map, .int, .uint, .double, .bool, .string, .timestamp, .bytes, .duration, .type, .nullType,
    ]
    if !verify(sub.id, ast, valid) {
      return sub.id
    }
    switch sub.kind {
    case .list(let list):
      for e in list.elements {
        if let bad = verifyString(e, ast) {
          return bad
        }
      }
    case .map(let map):
      for entry in map.entries {
        if let bad = verifyString(entry.key, ast) ?? verifyString(entry.value, ast) {
          return bad
        }
      }
    default:
      break
    }
    return nil
  }

  /// The checker clauses of `stringFormatChecker` / `stringFormatCheckerV2`.
  private static func check(_ clause: FormatClause, _ arg: Expr, _ ast: AST, v2: Bool) -> FormatError? {
    let id = arg.id
    let name = { (id: Int64) in ast.type(of: id).runtimeTypeName }
    switch clause {
    case .string:
      if let bad = verifyString(arg, ast) {
        return FormatErrors.string(bad, name(bad))
      }
    case .decimal:
      if !verify(id, ast, v2 ? [.int, .uint, .double] : [.int, .uint]) {
        return FormatErrors.decimal(id, name(id), v2: v2)
      }
    case .fixed:
      // Before version 4 strings are allowed for "NaN", "Infinity" and "-Infinity".
      if !verify(id, ast, v2 ? [.int, .uint, .double] : [.double, .string]) {
        return FormatErrors.fixedPoint(id, name(id), v2: v2)
      }
    case .scientific:
      if !verify(id, ast, v2 ? [.int, .uint, .double] : [.double, .string]) {
        return FormatErrors.scientific(id, name(id), v2: v2)
      }
    case .binary:
      if !verify(id, ast, [.bool, .int, .uint]) {
        return FormatErrors.binary(id, name(id), v2: v2)
      }
    case .hex:
      if !verify(id, ast, [.int, .uint, .string, .bytes]) {
        return FormatErrors.hex(id, name(id), v2: v2)
      }
    case .octal:
      if !verify(id, ast, [.int, .uint]) {
        return FormatErrors.octal(id, name(id), v2: v2)
      }
    }
    return nil
  }
}

enum NetworkValidators {
  static let validators: [ExpressionValidator] = [
    make(function: "ip") { s in
      if case .failure(let e) = NetworkLibrary.parseIP(s) { return e.message }
      return nil
    },
    make(function: "cidr") { s in
      if case .failure(let e) = NetworkLibrary.parseCIDR(s) { return e.message }
      return nil
    },
  ]

  /// Port of `networkFormatValidator` with `argNum` 0.
  private static func make(function: String, check: @escaping @Sendable (String) -> String?) -> ExpressionValidator {
    ExpressionValidator(name: "cel.validator.network.\(function)") { context, issues in
      for call in context.root.matchDescendants({ $0.expr.asCall?.function == function }) {
        guard let args = call.expr.asCall?.args, let arg = args.first,
          case .literal(let literal) = arg.kind
        else { continue }
        guard case .string(let s) = literal else { continue }
        if let message = check(s) {
          context.report(&issues, id: arg.id, "invalid \(function) argument: \(message)")
        }
      }
    }
  }
}

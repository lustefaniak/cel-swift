// Copyright 2022 Google LLC
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
// Ported from the macro expanders of cel-go ext/math.go (math.least, math.greatest),
// ext/lists.go (sortBy), ext/bindings.go (cel.bind), ext/comprehensions.go (two-variable
// comprehensions), ext/protos.go (proto.getExt, proto.hasExt), ext/guards.go
// (macroTargetMatchesNamespace) and the cel.block test macros of cel-go
// conformance/conformance_test.go.

import CEL

/// Port of `macroTargetMatchesNamespace`.
private func targetIs(_ namespace: String, _ target: Expr?) -> Bool {
  target?.asIdent == namespace
}

// MARK: - math.least / math.greatest

enum MathMacros {
  static let macros: [Macro] = [
    .receiverVarArg("least") { (eh: ExprHelper, target: Expr?, args: [Expr]) throws(CELError) -> Expr? in
      try expand(eh, target, args, name: "math.least()", function: MathLibrary.minFunc)
    },
    .receiverVarArg("greatest") { (eh: ExprHelper, target: Expr?, args: [Expr]) throws(CELError) -> Expr? in
      try expand(eh, target, args, name: "math.greatest()", function: MathLibrary.maxFunc)
    },
  ]

  /// Port of `mathLeast` / `mathGreatest`.
  private static func expand(
    _ eh: ExprHelper, _ target: Expr?, _ args: [Expr], name: String, function: String
  ) throws(CELError) -> Expr? {
    guard let target, targetIs("math", target) else {
      return nil
    }
    switch args.count {
    case 0:
      throw eh.newError(target.id, "\(name) requires at least one argument")
    case 1:
      if isListLiteralWithNumericArgs(args[0]) || isNumericArgType(args[0]) {
        return eh.newCall(function, args[0])
      }
      throw eh.newError(args[0].id, "\(name) invalid single argument value")
    case 2:
      try checkInvalidArgs(eh, name, args)
      return eh.newCall(function, args: args)
    default:
      try checkInvalidArgs(eh, name, args)
      return eh.newCall(function, eh.newList(args))
    }
  }

  private static func checkInvalidArgs(_ eh: ExprHelper, _ name: String, _ args: [Expr]) throws(CELError) {
    for arg in args where !isNumericArgType(arg) {
      throw eh.newError(arg.id, "\(name) simple literal arguments must be numeric")
    }
  }

  private static func isNumericArgType(_ arg: Expr) -> Bool {
    switch arg.kind {
    case .literal(let c):
      switch c {
      case .int, .uint, .double: return true
      default: return false
      }
    case .list, .map, .struct:
      return false
    default:
      return true
    }
  }

  private static func isListLiteralWithNumericArgs(_ arg: Expr) -> Bool {
    guard case .list(let list) = arg.kind, !list.elements.isEmpty else {
      return false
    }
    return list.elements.allSatisfy(isNumericArgType)
  }
}

// MARK: - sortBy

enum ListsMacros {
  /// Port of `sortByMacro`: `list.sortBy(e, key)` becomes a `cel.bind` of the list to
  /// `@__sortBy_input__` and `@__sortBy_input__.@sortByAssociatedKeys(@__sortBy_input__.map(e, key))`.
  static let sortBy = Macro.receiver("sortBy", argCount: 2) {
    (eh: ExprHelper, target: Expr?, args: [Expr]) throws(CELError) -> Expr? in
    guard let target else { return nil }
    let varIdent = eh.newIdent("@__sortBy_input__")
    let varName = "@__sortBy_input__"
    switch target.kind {
    case .list, .select, .ident, .comprehension, .call:
      break
    default:
      throw eh.newError(
        target.id,
        "sortBy can only be applied to a list, identifier, comprehension, call or select expression")
    }
    guard let mapCompr = try Macro.makeMap(eh, eh.copy(varIdent), args) else { return nil }
    let callExpr = eh.newMemberCall("@sortByAssociatedKeys", target: eh.copy(varIdent), mapCompr)
    return eh.newComprehension(
      iterRange: eh.newList(), iterVar: "#unused", accuVar: varName, accuInit: target,
      condition: eh.newLiteral(.bool(false)), step: varIdent, result: callExpr)
  }
}

// MARK: - cel.bind

enum BindingsMacros {
  /// Port of `celBind`: `cel.bind(v, init, result)` becomes a comprehension over an empty list
  /// whose accumulator `v` starts as `init`.
  static let bind = Macro.receiver("bind", argCount: 3) {
    (eh: ExprHelper, target: Expr?, args: [Expr]) throws(CELError) -> Expr? in
    guard targetIs("cel", target) else { return nil }
    guard let varName = args[0].asIdent else {
      throw eh.newError(args[0].id, "cel.bind() variable names must be simple identifiers")
    }
    return eh.newComprehension(
      iterRange: eh.newList(), iterVar: "#unused", accuVar: varName, accuInit: args[1],
      condition: eh.newLiteral(.bool(false)), step: eh.newIdent(varName), result: args[2])
  }
}

// MARK: - Two-variable comprehensions

enum ComprehensionMacros {
  static let macros: [Macro] = [
    .receiver("all", argCount: 3, expander: quantifierAll),
    .receiver("exists", argCount: 3, expander: quantifierExists),
    .receiver("existsOne", argCount: 3, expander: quantifierExistsOne),
    .receiver("exists_one", argCount: 3, expander: quantifierExistsOne),
    .receiver("transformList", argCount: 3, expander: transformList),
    .receiver("transformList", argCount: 4, expander: transformList),
    .receiver("transformMap", argCount: 3, expander: transformMap),
    .receiver("transformMap", argCount: 4, expander: transformMap),
    .receiver("transformMapEntry", argCount: 3, expander: transformMapEntry),
    .receiver("transformMapEntry", argCount: 4, expander: transformMapEntry),
  ]

  static let mapInsert = "cel.@mapInsert"

  private static func range(_ target: Expr?) -> Expr {
    target ?? .unspecified(id: 0)
  }

  @Sendable private static func quantifierAll(_ eh: ExprHelper, _ target: Expr?, _ args: [Expr]) throws(CELError)
    -> Expr?
  {
    let (v1, v2) = try extractIterVars(eh, args[0], args[1])
    return eh.newComprehensionTwoVar(
      iterRange: range(target), iterVar: v1, iterVar2: v2, accuVar: eh.accuIdentName,
      accuInit: eh.newLiteral(.bool(true)),
      condition: eh.newCall(Operators.notStrictlyFalse, eh.newAccuIdent()),
      step: eh.newCall(Operators.logicalAnd, eh.newAccuIdent(), args[2]),
      result: eh.newAccuIdent())
  }

  @Sendable private static func quantifierExists(_ eh: ExprHelper, _ target: Expr?, _ args: [Expr])
    throws(CELError) -> Expr?
  {
    let (v1, v2) = try extractIterVars(eh, args[0], args[1])
    return eh.newComprehensionTwoVar(
      iterRange: range(target), iterVar: v1, iterVar2: v2, accuVar: eh.accuIdentName,
      accuInit: eh.newLiteral(.bool(false)),
      condition: eh.newCall(
        Operators.notStrictlyFalse, eh.newCall(Operators.logicalNot, eh.newAccuIdent())),
      step: eh.newCall(Operators.logicalOr, eh.newAccuIdent(), args[2]),
      result: eh.newAccuIdent())
  }

  @Sendable private static func quantifierExistsOne(_ eh: ExprHelper, _ target: Expr?, _ args: [Expr])
    throws(CELError) -> Expr?
  {
    let (v1, v2) = try extractIterVars(eh, args[0], args[1])
    return eh.newComprehensionTwoVar(
      iterRange: range(target), iterVar: v1, iterVar2: v2, accuVar: eh.accuIdentName,
      accuInit: eh.newLiteral(.int(0)),
      condition: eh.newLiteral(.bool(true)),
      step: eh.newCall(
        Operators.conditional, args[2],
        eh.newCall(Operators.add, eh.newAccuIdent(), eh.newLiteral(.int(1))), eh.newAccuIdent()),
      result: eh.newCall(Operators.equals, eh.newAccuIdent(), eh.newLiteral(.int(1))))
  }

  @Sendable private static func transformList(_ eh: ExprHelper, _ target: Expr?, _ args: [Expr])
    throws(CELError) -> Expr?
  {
    let (v1, v2) = try extractIterVars(eh, args[0], args[1])
    let filter: Expr? = args.count == 4 ? args[2] : nil
    let transform = args.count == 4 ? args[3] : args[2]
    // accumulator = accumulator + [transform]
    var step = eh.newCall(Operators.add, eh.newAccuIdent(), eh.newList([transform]))
    if let filter {
      step = eh.newCall(Operators.conditional, filter, step, eh.newAccuIdent())
    }
    return eh.newComprehensionTwoVar(
      iterRange: range(target), iterVar: v1, iterVar2: v2, accuVar: eh.accuIdentName,
      accuInit: eh.newList(), condition: eh.newLiteral(.bool(true)), step: step,
      result: eh.newAccuIdent())
  }

  @Sendable private static func transformMap(_ eh: ExprHelper, _ target: Expr?, _ args: [Expr])
    throws(CELError) -> Expr?
  {
    let (v1, v2) = try extractIterVars(eh, args[0], args[1])
    let filter: Expr? = args.count == 4 ? args[2] : nil
    let transform = args.count == 4 ? args[3] : args[2]
    // accumulator = cel.@mapInsert(accumulator, iterVar1, transform)
    var step = eh.newCall(mapInsert, eh.newAccuIdent(), eh.newIdent(v1), transform)
    if let filter {
      step = eh.newCall(Operators.conditional, filter, step, eh.newAccuIdent())
    }
    return eh.newComprehensionTwoVar(
      iterRange: range(target), iterVar: v1, iterVar2: v2, accuVar: eh.accuIdentName,
      accuInit: eh.newMap(), condition: eh.newLiteral(.bool(true)), step: step,
      result: eh.newAccuIdent())
  }

  @Sendable private static func transformMapEntry(_ eh: ExprHelper, _ target: Expr?, _ args: [Expr])
    throws(CELError) -> Expr?
  {
    let (v1, v2) = try extractIterVars(eh, args[0], args[1])
    let filter: Expr? = args.count == 4 ? args[2] : nil
    let transform = args.count == 4 ? args[3] : args[2]
    // accumulator = cel.@mapInsert(accumulator, transform)
    var step = eh.newCall(mapInsert, eh.newAccuIdent(), transform)
    if let filter {
      step = eh.newCall(Operators.conditional, filter, step, eh.newAccuIdent())
    }
    return eh.newComprehensionTwoVar(
      iterRange: range(target), iterVar: v1, iterVar2: v2, accuVar: eh.accuIdentName,
      accuInit: eh.newMap(), condition: eh.newLiteral(.bool(true)), step: step,
      result: eh.newAccuIdent())
  }

  private static func extractIterVars(_ eh: ExprHelper, _ arg0: Expr, _ arg1: Expr) throws(CELError)
    -> (String, String)
  {
    let v1 = try extractIterVar(eh, arg0)
    let v2 = try extractIterVar(eh, arg1)
    if v1 == v2 {
      throw eh.newError(arg1.id, "duplicate variable name: \(v1)")
    }
    if v1 == eh.accuIdentName || v1 == Macro.accumulatorName {
      throw eh.newError(arg0.id, "iteration variable overwrites accumulator variable")
    }
    if v2 == eh.accuIdentName || v2 == Macro.accumulatorName {
      throw eh.newError(arg1.id, "iteration variable overwrites accumulator variable")
    }
    return (v1, v2)
  }

  private static func extractIterVar(_ eh: ExprHelper, _ target: Expr) throws(CELError) -> String {
    guard let name = target.asIdent else {
      throw eh.newError(target.id, "argument must be a simple name")
    }
    return name
  }
}

// MARK: - proto.getExt / proto.hasExt

enum ProtosMacros {
  static let macros: [Macro] = [
    .receiver("getExt", argCount: 2) { (eh: ExprHelper, target: Expr?, args: [Expr]) throws(CELError) -> Expr? in
      guard targetIs("proto", target) else { return nil }
      let field = try extFieldName(eh, args[1])
      return eh.newSelect(operand: args[0], field: field)
    },
    .receiver("hasExt", argCount: 2) { (eh: ExprHelper, target: Expr?, args: [Expr]) throws(CELError) -> Expr? in
      guard targetIs("proto", target) else { return nil }
      let field = try extFieldName(eh, args[1])
      return eh.newPresenceTest(operand: args[0], field: field)
    },
  ]

  /// Port of `getExtFieldName`: the argument must be a qualified name written as a selection.
  private static func extFieldName(_ eh: ExprHelper, _ expr: Expr) throws(CELError) -> String {
    if case .select = expr.kind, let name = qualifiedName(expr) {
      return name
    }
    throw eh.newError(expr.id, "invalid extension field")
  }

  /// Port of `validateIdentifier`.
  private static func qualifiedName(_ expr: Expr) -> String? {
    switch expr.kind {
    case .ident(let name):
      return name
    case .select(let sel):
      if sel.testOnly {
        return nil
      }
      guard let operand = qualifiedName(sel.operand) else { return nil }
      return operand + "." + sel.field
    default:
      return nil
    }
  }
}

// MARK: - cel.block test macros (cel-go conformance)

enum BlockMacros {
  private static func isNonNegativeInt(_ expr: Expr) -> Int64? {
    if case .literal(.int(let v)) = expr.kind, v >= 0 {
      return v
    }
    return nil
  }

  static let macros: [Macro] = [
    // cel.block([args], expr)
    .receiver("block", argCount: 2) { (eh: ExprHelper, target: Expr?, args: [Expr]) throws(CELError) -> Expr? in
      guard targetIs("cel", target) else { return nil }
      guard case .list = args[0].kind else {
        throw eh.newError(args[0].id, "cel.block requires the first arg to be a list literal")
      }
      return eh.newCall("cel.@block", args: args)
    },
    // cel.index(int)
    .receiver("index", argCount: 1) { (eh: ExprHelper, target: Expr?, args: [Expr]) throws(CELError) -> Expr? in
      guard targetIs("cel", target) else { return nil }
      guard let index = isNonNegativeInt(args[0]) else {
        throw eh.newError(args[0].id, "cel.index requires a single non-negative int constant arg")
      }
      return eh.newIdent("@index\(index)")
    },
    compreVar("iterVar", "cel.iterVar", "@it"),
    compreVar("accuVar", "cel.accuVar", "@ac"),
  ]

  private static func compreVar(_ name: String, _ funcName: String, _ prefix: String) -> Macro {
    .receiver(name, argCount: 2) { (eh: ExprHelper, target: Expr?, args: [Expr]) throws(CELError) -> Expr? in
      guard targetIs("cel", target) else { return nil }
      guard let depth = isNonNegativeInt(args[0]) else {
        throw eh.newError(args[0].id, "\(funcName) requires two non-negative int constant args")
      }
      guard let unique = isNonNegativeInt(args[1]) else {
        throw eh.newError(args[1].id, "\(funcName) requires two non-negative int constant args")
      }
      return eh.newIdent("\(prefix):\(depth):\(unique)")
    }
  }
}

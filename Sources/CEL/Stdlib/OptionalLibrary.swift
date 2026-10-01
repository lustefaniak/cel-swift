// Copyright 2020 Google LLC
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
// Ported from cel-go cel/library.go (optionalLib, optMap, optFlatMap, optUnwrap, decorateOptionalOr,
// evalOptionalOr, evalOptionalOrValue).

/// The optional types library (cel-go `cel.OptionalTypes`): `optional.of`, `optional.none`,
/// `optional.ofNonZeroValue`, `value`, `hasValue`, `or`, `orValue`, the `optMap` / `optFlatMap`
/// macros, the `_?._` / `_[?_]` declarations, and from version 2 `first`, `last`,
/// `optional.unwrap` and `unwrapOpt`.
package enum OptionalLibrary {
  static let optMapMacro = "optMap"
  static let optFlatMapMacro = "optFlatMap"
  static let hasValueFunc = "hasValue"
  static let unwrapOptFunc = "unwrapOpt"
  static let optionalNoneFunc = "optional.none"
  static let optionalOfFunc = "optional.of"
  static let optionalOfNonZeroValueFunc = "optional.ofNonZeroValue"
  static let optionalUnwrapFunc = "optional.unwrap"
  static let valueFunc = "value"
  static let unusedIterVar = "#unused"
  static let targetVar = "@target"

  /// The latest library version.
  package static let latestVersion: UInt32 = .max

  /// The `optional_type` type identifier.
  package static let types: [VariableDecl] = [.typeIdentifier(.optionalOfDyn)]

  /// The macros of the library version.
  package static func macros(version: UInt32 = latestVersion) -> [Macro] {
    var out = [optMap]
    if version >= 1 {
      out.append(optFlatMap)
    }
    return out
  }

  /// The function declarations, with bindings, of the library version.
  package static func functions(version: UInt32 = latestVersion) -> [FunctionDecl] {
    do {
      return try declareFunctions(version: version)
    } catch {
      preconditionFailure("invalid optional library declaration: \(error)")
    }
  }

  /// The planner decorator making `or` and `orValue` short-circuit.
  package static let decorator: ProgramDecorator = { i in decorateOptionalOr(i) }

  // swift-format-ignore: FunctionLength
  private static func declareFunctions(version: UInt32) throws -> [FunctionDecl] {
    let paramK = CELType.typeParam("K")
    let paramV = CELType.typeParam("V")
    let optionalV = CELType.optional(paramV)
    let listV = CELType.list(paramV)
    let mapKV = CELType.map(key: paramK, value: paramV)
    let listOptionalV = CELType.list(optionalV)

    var out = [
      try FunctionDecl(
        optionalOfFunc,
        .documentation("create a new optional_type(T) with a value where any value is considered valid"),
        .overload(
          "optional_of", argumentTypes: [paramV], resultType: optionalV,
          .examples("optional.of(1) // optional(1)"),
          .unaryBinding { value in .optional(value) })),
      try FunctionDecl(
        optionalOfNonZeroValueFunc,
        .documentation("create a new optional_type(T) with a value, if the value is not a zero or empty value"),
        .overload(
          "optional_ofNonZeroValue", argumentTypes: [paramV], resultType: optionalV,
          .unaryBinding { value in value.isZeroValue ? .optional(nil) : .optional(value) })),
      try FunctionDecl(
        optionalNoneFunc,
        .documentation("singleton value representing an optional without a value"),
        .overload(
          "optional_none", argumentTypes: [], resultType: optionalV,
          .functionBinding { _ in .optional(nil) })),
      try FunctionDecl(
        valueFunc,
        .documentation("obtain the value contained by the optional, error if optional.none()"),
        .memberOverload(
          "optional_value", argumentTypes: [optionalV], resultType: paramV,
          .unaryBinding { value in
            guard case .optional(let inner) = value else { return .noSuchOverload }
            return inner ?? .error(message: "optional.none() dereference")
          })),
      try FunctionDecl(
        hasValueFunc,
        .documentation("determine whether the optional contains a value"),
        .memberOverload(
          "optional_hasValue", argumentTypes: [optionalV], resultType: .bool,
          .unaryBinding { value in
            guard case .optional(let inner) = value else { return .noSuchOverload }
            return .bool(inner != nil)
          })),
      // `or` and `orValue` are implemented by the decorator so they short-circuit.
      try FunctionDecl(
        "or",
        .documentation("chain optional expressions together, picking the first valued optional expression"),
        .memberOverload("optional_or_optional", argumentTypes: [optionalV, optionalV], resultType: optionalV)),
      try FunctionDecl(
        "orValue",
        .documentation("chain optional expressions together picking the first valued optional or the default value"),
        .memberOverload("optional_orValue_value", argumentTypes: [optionalV, paramV], resultType: paramV)),
      // The type checker handles optional selection specially, using the field type.
      try FunctionDecl(
        Operators.optSelect,
        .documentation("if the field is present create an optional of the field value, otherwise return optional.none()"),
        .overload("select_optional_field", argumentTypes: [.dyn, .string], resultType: optionalV)),
      try FunctionDecl(
        Operators.optIndex,
        .documentation("if the index is present create an optional of the field value, otherwise return optional.none()"),
        .overload("list_optindex_optional_int", argumentTypes: [listV, .int], resultType: optionalV),
        .overload(
          "optional_list_optindex_optional_int", argumentTypes: [.optional(listV), .int], resultType: optionalV),
        .overload("map_optindex_optional_value", argumentTypes: [mapKV, paramK], resultType: optionalV),
        .overload(
          "optional_map_optindex_optional_value", argumentTypes: [.optional(mapKV), paramK], resultType: optionalV)),
      // Index overloads accepting an optional operand.
      try FunctionDecl(
        Operators.index,
        .overload("optional_list_index_int", argumentTypes: [.optional(listV), .int], resultType: optionalV),
        .overload("optional_map_index_value", argumentTypes: [.optional(mapKV), paramK], resultType: optionalV)),
    ]
    if version >= 2 {
      out += [
        try FunctionDecl(
          "last",
          .documentation("return the last value in a list if present, otherwise optional.none()"),
          .memberOverload(
            "list_last", argumentTypes: [listV], resultType: optionalV,
            .unaryBinding { v in
              guard case .list(let l) = v else { return .noSuchOverload }
              return l.count == 0 ? .optional(nil) : .optional(l.element(at: l.count - 1))
            })),
        try FunctionDecl(
          "first",
          .documentation("return the first value in a list if present, otherwise optional.none()"),
          .memberOverload(
            "list_first", argumentTypes: [listV], resultType: optionalV,
            .unaryBinding { v in
              guard case .list(let l) = v else { return .noSuchOverload }
              return l.count == 0 ? .optional(nil) : .optional(l.element(at: 0))
            })),
        try FunctionDecl(
          optionalUnwrapFunc,
          .documentation("convert a list of optional values to a list containing only value which are not optional.none()"),
          .overload("optional_unwrap", argumentTypes: [listOptionalV], resultType: listV, .unaryBinding(optUnwrap))),
        try FunctionDecl(
          unwrapOptFunc,
          .documentation("convert a list of optional values to a list containing only value which are not optional.none()"),
          .memberOverload("optional_unwrapOpt", argumentTypes: [listOptionalV], resultType: listV, .unaryBinding(optUnwrap))),
      ]
    }
    return out
  }

  @Sendable private static func optUnwrap(_ value: Value) -> Value {
    guard case .list(let list) = value else { return .noSuchOverload }
    var out: [Value] = []
    for i in 0..<list.count {
      let v = list.element(at: i)
      guard case .optional(let inner) = v else {
        return .error(message: "value \(formatGoValue(v)) is not optional")
      }
      if let inner {
        out.append(inner)
      }
    }
    return .list(ArrayList(out))
  }

  // MARK: Macros

  /// `opt.optMap(x, expr)`: `optional.of(expr)` with `x` bound to the value, or `optional.none()`.
  package static let optMap = Macro.receiver(optMapMacro, argCount: 2) {
    (eh: ExprHelper, target: Expr?, args: [Expr]) throws(CELError) -> Expr? in
    try makeOptMap(eh, target, args, flat: false)
  }

  /// `opt.optFlatMap(x, expr)`: `expr` (an optional) with `x` bound to the value, or `optional.none()`.
  package static let optFlatMap = Macro.receiver(optFlatMapMacro, argCount: 2) {
    (eh: ExprHelper, target: Expr?, args: [Expr]) throws(CELError) -> Expr? in
    try makeOptMap(eh, target, args, flat: true)
  }

  private static func makeOptMap(_ eh: ExprHelper, _ target: Expr?, _ args: [Expr], flat: Bool)
    throws(CELError) -> Expr?
  {
    guard let target else { return nil }
    guard let varName = args[0].asIdent else {
      throw eh.newError(
        args[0].id, "\(flat ? optFlatMapMacro : optMapMacro)() variable name must be a simple identifier")
    }
    let mapExpr = args[1]
    let targetIsIdent = target.asIdent != nil
    let targetIdent = targetIsIdent ? target : eh.newIdent(targetVar)
    let bound = eh.newComprehension(
      iterRange: eh.newList(), iterVar: unusedIterVar, accuVar: varName,
      accuInit: eh.newMemberCall(valueFunc, target: eh.copy(targetIdent)),
      condition: eh.newLiteral(.bool(false)), step: eh.newIdent(varName), result: mapExpr)
    let res = eh.newCall(
      Operators.conditional,
      eh.newMemberCall(hasValueFunc, target: targetIdent),
      flat ? bound : eh.newCall(optionalOfFunc, bound),
      eh.newCall(optionalNoneFunc))
    if targetIsIdent {
      return res
    }
    return eh.newComprehension(
      iterRange: eh.newList(), iterVar: unusedIterVar, accuVar: targetVar, accuInit: target,
      condition: eh.newLiteral(.bool(false)), step: eh.newIdent(targetVar), result: res)
  }

  // MARK: Short-circuiting or / orValue

  static func decorateOptionalOr(_ i: any Interpretable) -> any Interpretable {
    guard let call = i as? any InterpretableCall else { return i }
    let args = call.args
    guard args.count == 2 else { return i }
    switch call.function {
    case "or":
      if !call.overloadID.isEmpty && call.overloadID != "optional_or_optional" { return i }
      return EvalOptionalOr(id: call.id, lhs: args[0], rhs: args[1], orValue: false)
    case "orValue":
      if !call.overloadID.isEmpty && call.overloadID != "optional_orValue_value" { return i }
      return EvalOptionalOr(id: call.id, lhs: args[0], rhs: args[1], orValue: true)
    default:
      return i
    }
  }
}

/// `lhs.or(rhs)` / `lhs.orValue(rhs)`, evaluating `rhs` only when `lhs` is `optional.none()`
/// (cel-go `evalOptionalOr` / `evalOptionalOrValue`).
final class EvalOptionalOr: Interpretable {
  let id: Int64
  let lhs: any Interpretable
  let rhs: any Interpretable
  let orValue: Bool

  init(id: Int64, lhs: any Interpretable, rhs: any Interpretable, orValue: Bool) {
    self.id = id
    self.lhs = lhs
    self.rhs = rhs
    self.orValue = orValue
  }

  func eval(_ frame: ExecutionFrame) -> Value {
    let optLHS = lhs.eval(frame)
    switch optLHS {
    case .error, .unknown:
      return optLHS
    case .optional(let inner):
      if let inner {
        return orValue ? inner : optLHS
      }
      return rhs.eval(frame)
    default:
      return .noSuchOverload
    }
  }
}

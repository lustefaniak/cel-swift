// Copyright 2018 Google LLC
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

// Ported from cel-go parser/macro.go and the exprHelper of parser/helper.go.

/// Expands a call matched by a macro into a new expression.
///
/// - Parameters:
///   - helper: creates expressions with ids consistent with the parser.
///   - target: the receiver of a receiver-style call, `nil` for global calls.
///   - args: the call arguments.
/// - Returns: the expansion, or `nil` when the macro decides not to expand this call.
/// - Throws: a `CELError` when the call matches but its arguments are malformed.
package typealias MacroExpander =
  @Sendable (_ helper: ExprHelper, _ target: Expr?, _ args: [Expr]) throws(CELError) -> Expr?

/// A macro: the function signature it matches and how to expand it (cel-go `parser.Macro`).
package struct Macro: Sendable {
  /// The function name to match.
  package let function: String
  /// The argument count to match; 0 for var-arg macros.
  package let argCount: Int
  /// Whether the macro matches receiver-style calls.
  package let isReceiverStyle: Bool
  /// Whether the macro matches any argument count.
  package let isVarArgStyle: Bool
  /// The expansion function.
  package let expander: MacroExpander
  /// Documentation lines.
  package let documentation: [String]
  /// Usage examples.
  package let examples: [String]

  private init(
    function: String, argCount: Int, isReceiverStyle: Bool, isVarArgStyle: Bool,
    documentation: [String], examples: [String], expander: @escaping MacroExpander
  ) {
    self.function = function
    self.argCount = argCount
    self.isReceiverStyle = isReceiverStyle
    self.isVarArgStyle = isVarArgStyle
    self.expander = expander
    self.documentation = documentation
    self.examples = examples
  }

  /// A macro for a global function with the given argument count.
  package static func global(
    _ function: String, argCount: Int, documentation: [String] = [], examples: [String] = [],
    expander: @escaping MacroExpander
  ) -> Macro {
    Macro(
      function: function, argCount: argCount, isReceiverStyle: false, isVarArgStyle: false,
      documentation: documentation, examples: examples, expander: expander)
  }

  /// A macro for a receiver-style function with the given argument count.
  package static func receiver(
    _ function: String, argCount: Int, documentation: [String] = [], examples: [String] = [],
    expander: @escaping MacroExpander
  ) -> Macro {
    Macro(
      function: function, argCount: argCount, isReceiverStyle: true, isVarArgStyle: false,
      documentation: documentation, examples: examples, expander: expander)
  }

  /// A macro for a global function with any argument count.
  package static func globalVarArg(
    _ function: String, documentation: [String] = [], examples: [String] = [],
    expander: @escaping MacroExpander
  ) -> Macro {
    Macro(
      function: function, argCount: 0, isReceiverStyle: false, isVarArgStyle: true,
      documentation: documentation, examples: examples, expander: expander)
  }

  /// A macro for a receiver-style function with any argument count.
  package static func receiverVarArg(
    _ function: String, documentation: [String] = [], examples: [String] = [],
    expander: @escaping MacroExpander
  ) -> Macro {
    Macro(
      function: function, argCount: 0, isReceiverStyle: true, isVarArgStyle: true,
      documentation: documentation, examples: examples, expander: expander)
  }

  /// The signature key: `<function>:<arg-count>:<is-receiver>`, with `*` for var-arg macros.
  package var key: String {
    isVarArgStyle
      ? Macro.varArgKey(function, receiverStyle: isReceiverStyle)
      : Macro.key(function, argCount, receiverStyle: isReceiverStyle)
  }

  static func key(_ name: String, _ args: Int, receiverStyle: Bool) -> String {
    "\(name):\(args):\(receiverStyle)"
  }

  static func varArgKey(_ name: String, receiverStyle: Bool) -> String {
    "\(name):*:\(receiverStyle)"
  }
}

/// Creates expressions for macro expansions with ids consistent with the parser
/// (cel-go `parser.ExprHelper`).
///
/// Every node created gets a fresh id whose source offset is the location of the expanded call.
package final class ExprHelper {
  private let helper: ParserHelper
  /// The id of the call being expanded.
  private let callID: Int64

  init(helper: ParserHelper, callID: Int64) {
    self.helper = helper
    self.callID = callID
  }

  private func nextMacroID() -> Int64 {
    helper.id(.location(helper.location(callID)))
  }

  /// A copy of `expr` with a fresh set of ids for it and all its descendants.
  package func copy(_ expr: Expr) -> Expr {
    let offsetRange = helper.sourceInfo.offsetRange(expr.id) ?? OffsetRange(start: 0, stop: 0)
    let copyID = helper.newID(.offsetRange(offsetRange))
    switch expr.kind {
    case .literal(let c):
      return .literal(id: copyID, c)
    case .ident(let name):
      return .ident(id: copyID, name)
    case .select(let sel):
      let op = copy(sel.operand)
      if sel.testOnly {
        return .presenceTest(id: copyID, operand: op, field: sel.field)
      }
      return .select(id: copyID, operand: op, field: sel.field)
    case .call(let call):
      let argsCopy = call.args.map { copy($0) }
      guard let target = call.target else {
        return .call(id: copyID, function: call.function, args: argsCopy)
      }
      return .memberCall(id: copyID, function: call.function, target: copy(target), args: argsCopy)
    case .list(let list):
      let elemsCopy = list.elements.map { copy($0) }
      return .list(id: copyID, elements: elemsCopy, optionalIndices: list.optionalIndices)
    case .map(let m):
      var entriesCopy: [Expr.MapEntry] = []
      for entry in m.entries {
        let entryID = nextMacroID()
        let key = copy(entry.key)
        let value = copy(entry.value)
        entriesCopy.append(
          Expr.MapEntry(id: entryID, key: key, value: value, isOptional: entry.isOptional))
      }
      return .map(id: copyID, entries: entriesCopy)
    case .struct(let s):
      var fieldsCopy: [Expr.StructField] = []
      for field in s.fields {
        let fieldID = nextMacroID()
        let value = copy(field.value)
        fieldsCopy.append(
          Expr.StructField(id: fieldID, name: field.name, value: value, isOptional: field.isOptional))
      }
      return .struct(id: copyID, typeName: s.typeName, fields: fieldsCopy)
    case .comprehension(let c):
      let iterRange = copy(c.iterRange)
      let accuInit = copy(c.accuInit)
      let cond = copy(c.loopCondition)
      let step = copy(c.loopStep)
      let result = copy(c.result)
      return .comprehension(
        id: copyID, iterRange: iterRange, iterVar: c.iterVar, iterVar2: c.iterVar2,
        accuVar: c.accuVar, accuInit: accuInit, loopCondition: cond, loopStep: step, result: result)
    case .unspecified:
      return .unspecified(id: copyID)
    }
  }

  /// A literal.
  package func newLiteral(_ value: Constant) -> Expr {
    .literal(id: nextMacroID(), value)
  }

  /// A list literal.
  package func newList(_ elements: [Expr] = []) -> Expr {
    .list(id: nextMacroID(), elements: elements, optionalIndices: [])
  }

  /// A map literal.
  package func newMap(_ entries: [Expr.MapEntry] = []) -> Expr {
    .map(id: nextMacroID(), entries: entries)
  }

  /// A map entry.
  package func newMapEntry(key: Expr, value: Expr, isOptional: Bool) -> Expr.MapEntry {
    Expr.MapEntry(id: nextMacroID(), key: key, value: value, isOptional: isOptional)
  }

  /// A message literal.
  package func newStruct(typeName: String, fields: [Expr.StructField] = []) -> Expr {
    .struct(id: nextMacroID(), typeName: typeName, fields: fields)
  }

  /// A message field initializer.
  package func newStructField(name: String, value: Expr, isOptional: Bool) -> Expr.StructField {
    Expr.StructField(id: nextMacroID(), name: name, value: value, isOptional: isOptional)
  }

  /// A one-variable comprehension.
  package func newComprehension(
    iterRange: Expr, iterVar: String, accuVar: String, accuInit: Expr, condition: Expr, step: Expr,
    result: Expr
  ) -> Expr {
    .comprehension(
      id: nextMacroID(), iterRange: iterRange, iterVar: iterVar, accuVar: accuVar,
      accuInit: accuInit, loopCondition: condition, loopStep: step, result: result)
  }

  /// A two-variable comprehension.
  package func newComprehensionTwoVar(
    iterRange: Expr, iterVar: String, iterVar2: String, accuVar: String, accuInit: Expr,
    condition: Expr, step: Expr, result: Expr
  ) -> Expr {
    .comprehension(
      id: nextMacroID(), iterRange: iterRange, iterVar: iterVar, iterVar2: iterVar2,
      accuVar: accuVar, accuInit: accuInit, loopCondition: condition, loopStep: step,
      result: result)
  }

  /// An identifier.
  package func newIdent(_ name: String) -> Expr {
    .ident(id: nextMacroID(), name)
  }

  /// An identifier referring to the comprehension accumulator.
  package func newAccuIdent() -> Expr {
    .ident(id: nextMacroID(), helper.factory.accumulatorName)
  }

  /// The name of the comprehension accumulator variable.
  package var accuIdentName: String {
    helper.factory.accumulatorName
  }

  /// A global function call.
  package func newCall(_ function: String, _ args: Expr...) -> Expr {
    newCall(function, args: args)
  }

  /// A global function call.
  package func newCall(_ function: String, args: [Expr]) -> Expr {
    .call(id: nextMacroID(), function: function, args: args)
  }

  /// A member function call.
  package func newMemberCall(_ function: String, target: Expr, _ args: Expr...) -> Expr {
    newMemberCall(function, target: target, args: args)
  }

  /// A member function call.
  package func newMemberCall(_ function: String, target: Expr, args: [Expr]) -> Expr {
    .memberCall(id: nextMacroID(), function: function, target: target, args: args)
  }

  /// A presence test `has(operand.field)`.
  package func newPresenceTest(operand: Expr, field: String) -> Expr {
    .presenceTest(id: nextMacroID(), operand: operand, field: field)
  }

  /// A field selection.
  package func newSelect(operand: Expr, field: String) -> Expr {
    .select(id: nextMacroID(), operand: operand, field: field)
  }

  /// The source location of the expression with the given id.
  package func offsetLocation(_ exprID: Int64) -> Location {
    helper.sourceInfo.startLocation(exprID)
  }

  /// An error attached to the expression with the given id, located at its source position.
  package func newError(_ exprID: Int64, _ message: String) -> CELError {
    CELError(exprID: exprID, message: message, location: offsetLocation(exprID))
  }
}

// MARK: - Standard macros

extension Macro {
  /// The traditional accumulator variable name.
  package static let accumulatorName = "__result__"

  /// The hidden accumulator variable name, not accessible from source.
  package static let hiddenAccumulatorName = "@result"

  /// `has(m.f)`: tests the presence of a field.
  package static let has = Macro.global(Operators.has, argCount: 1) { (eh: ExprHelper, _: Expr?, args: [Expr]) throws(CELError) -> Expr? in
    if case .select(let s) = args[0].kind {
      return eh.newPresenceTest(operand: s.operand, field: s.field)
    }
    throw eh.newError(args[0].id, "invalid argument to has() macro")
  }

  /// `range.all(var, predicate)`.
  package static let all = Macro.receiver(Operators.all, argCount: 2) {
    (eh: ExprHelper, target: Expr?, args: [Expr]) throws(CELError) -> Expr? in
    try makeQuantifier(.all, eh, target, args)
  }

  /// `range.exists(var, predicate)`.
  package static let exists = Macro.receiver(Operators.exists, argCount: 2) {
    (eh: ExprHelper, target: Expr?, args: [Expr]) throws(CELError) -> Expr? in
    try makeQuantifier(.exists, eh, target, args)
  }

  /// `range.exists_one(var, predicate)`.
  package static let existsOne = Macro.receiver(Operators.existsOne, argCount: 2) {
    (eh: ExprHelper, target: Expr?, args: [Expr]) throws(CELError) -> Expr? in
    try makeQuantifier(.existsOne, eh, target, args)
  }

  /// `range.existsOne(var, predicate)`.
  package static let existsOneNew = Macro.receiver("existsOne", argCount: 2) {
    (eh: ExprHelper, target: Expr?, args: [Expr]) throws(CELError) -> Expr? in
    try makeQuantifier(.existsOne, eh, target, args)
  }

  /// `range.map(var, function)`.
  package static let map = Macro.receiver(Operators.map, argCount: 2) {
    (eh: ExprHelper, target: Expr?, args: [Expr]) throws(CELError) -> Expr? in
    try makeMap(eh, target, args)
  }

  /// `range.map(var, predicate, function)`.
  package static let mapFilter = Macro.receiver(Operators.map, argCount: 3) {
    (eh: ExprHelper, target: Expr?, args: [Expr]) throws(CELError) -> Expr? in
    try makeMap(eh, target, args)
  }

  /// `range.filter(var, predicate)`.
  package static let filter = Macro.receiver(Operators.filter, argCount: 2) {
    (eh: ExprHelper, target: Expr?, args: [Expr]) throws(CELError) -> Expr? in
    try makeFilter(eh, target, args)
  }

  /// All spec-supported macros.
  package static let allMacros: [Macro] = [
    has, all, exists, existsOne, existsOneNew, map, mapFilter, filter,
  ]

  private enum QuantifierKind {
    case all
    case exists
    case existsOne
  }

  private static func extractIdent(_ e: Expr) -> String? {
    e.asIdent
  }

  private static func makeQuantifier(
    _ kind: QuantifierKind, _ eh: ExprHelper, _ target: Expr?, _ args: [Expr]
  ) throws(CELError) -> Expr? {
    guard let v = extractIdent(args[0]) else {
      throw eh.newError(args[0].id, "argument must be a simple name")
    }
    let accu = eh.accuIdentName
    if v == accu || v == accumulatorName {
      throw eh.newError(args[0].id, "iteration variable overwrites accumulator variable")
    }
    let initExpr: Expr
    let condition: Expr
    let step: Expr
    let result: Expr
    switch kind {
    case .all:
      initExpr = eh.newLiteral(.bool(true))
      condition = eh.newCall(Operators.notStrictlyFalse, eh.newAccuIdent())
      step = eh.newCall(Operators.logicalAnd, eh.newAccuIdent(), args[1])
      result = eh.newAccuIdent()
    case .exists:
      initExpr = eh.newLiteral(.bool(false))
      condition = eh.newCall(
        Operators.notStrictlyFalse, eh.newCall(Operators.logicalNot, eh.newAccuIdent()))
      step = eh.newCall(Operators.logicalOr, eh.newAccuIdent(), args[1])
      result = eh.newAccuIdent()
    case .existsOne:
      initExpr = eh.newLiteral(.int(0))
      condition = eh.newLiteral(.bool(true))
      step = eh.newCall(
        Operators.conditional, args[1],
        eh.newCall(Operators.add, eh.newAccuIdent(), eh.newLiteral(.int(1))), eh.newAccuIdent())
      result = eh.newCall(Operators.equals, eh.newAccuIdent(), eh.newLiteral(.int(1)))
    }
    return eh.newComprehension(
      iterRange: target ?? .unspecified(id: 0), iterVar: v, accuVar: accu, accuInit: initExpr, condition: condition,
      step: step, result: result)
  }

  private static func makeMap(_ eh: ExprHelper, _ target: Expr?, _ args: [Expr]) throws(CELError)
    -> Expr?
  {
    guard let v = extractIdent(args[0]) else {
      throw eh.newError(args[0].id, "argument is not an identifier")
    }
    let accu = eh.accuIdentName
    if v == accu || v == accumulatorName {
      throw eh.newError(args[0].id, "iteration variable overwrites accumulator variable")
    }
    let fn: Expr
    var filter: Expr? = nil
    if args.count == 3 {
      filter = args[1]
      fn = args[2]
    } else {
      fn = args[1]
    }
    let initExpr = eh.newList()
    let condition = eh.newLiteral(.bool(true))
    var step = eh.newCall(Operators.add, eh.newAccuIdent(), eh.newList([fn]))
    if let filter {
      step = eh.newCall(Operators.conditional, filter, step, eh.newAccuIdent())
    }
    return eh.newComprehension(
      iterRange: target ?? .unspecified(id: 0), iterVar: v, accuVar: accu, accuInit: initExpr, condition: condition,
      step: step, result: eh.newAccuIdent())
  }

  private static func makeFilter(_ eh: ExprHelper, _ target: Expr?, _ args: [Expr]) throws(CELError)
    -> Expr?
  {
    guard let v = extractIdent(args[0]) else {
      throw eh.newError(args[0].id, "argument is not an identifier")
    }
    let accu = eh.accuIdentName
    if v == accu || v == accumulatorName {
      throw eh.newError(args[0].id, "iteration variable overwrites accumulator variable")
    }
    let filter = args[1]
    let initExpr = eh.newList()
    let condition = eh.newLiteral(.bool(true))
    var step = eh.newCall(Operators.add, eh.newAccuIdent(), eh.newList([args[0]]))
    step = eh.newCall(Operators.conditional, filter, step, eh.newAccuIdent())
    return eh.newComprehension(
      iterRange: target ?? .unspecified(id: 0), iterVar: v, accuVar: accu, accuInit: initExpr, condition: condition,
      step: step, result: eh.newAccuIdent())
  }
}

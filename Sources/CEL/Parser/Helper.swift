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

// Ported from cel-go parser/helper.go.

/// What an expression id is derived from: cel-go's `id(ctx any)` switches on the dynamic type.
enum IDSource {
  /// A parse tree node: offsets from its start token and the byte length of its text.
  case context(ParserRuleContext?)
  /// A token: offsets from the token position and the byte length of its text.
  case token(Token?)
  /// An absolute location; start and stop are equal.
  case location(Location)
  /// An explicit offset range.
  case offsetRange(OffsetRange)
  /// An already allocated id (cel-go passes `int64` values through `newID`).
  case id(Int64)
}

/// Allocates expression ids and records their source offsets (cel-go `parserHelper`).
final class ParserHelper {
  let factory: ExprFactory
  var sourceInfo: SourceInfo
  var nextID: Int64 = 1

  init(source: any Source, factory: ExprFactory) {
    self.factory = factory
    self.sourceInfo = SourceInfo(source: source)
  }

  var expressionCount: Int64 {
    nextID - 1
  }

  func newLiteral(_ ctx: IDSource, _ value: Constant) -> Expr {
    .literal(id: newID(ctx), value)
  }

  func newIdent(_ ctx: IDSource, _ name: String) -> Expr {
    .ident(id: newID(ctx), name)
  }

  func newSelect(_ ctx: IDSource, _ operand: Expr, _ field: String) -> Expr {
    .select(id: newID(ctx), operand: operand, field: field)
  }

  func newPresenceTest(_ ctx: IDSource, _ operand: Expr, _ field: String) -> Expr {
    .presenceTest(id: newID(ctx), operand: operand, field: field)
  }

  func newGlobalCall(_ ctx: IDSource, _ function: String, _ args: [Expr]) -> Expr {
    .call(id: newID(ctx), function: function, args: args)
  }

  func newReceiverCall(_ ctx: IDSource, _ function: String, _ target: Expr, _ args: [Expr]) -> Expr {
    .memberCall(id: newID(ctx), function: function, target: target, args: args)
  }

  func newList(_ ctx: IDSource, _ elements: [Expr], _ optionals: [Int32]) -> Expr {
    .list(id: newID(ctx), elements: elements, optionalIndices: optionals)
  }

  func newMap(_ ctx: IDSource, _ entries: [Expr.MapEntry]) -> Expr {
    .map(id: newID(ctx), entries: entries)
  }

  func newMapEntry(_ entryID: Int64, _ key: Expr, _ value: Expr, _ optional: Bool) -> Expr.MapEntry {
    Expr.MapEntry(id: entryID, key: key, value: value, isOptional: optional)
  }

  func newObject(_ ctx: IDSource, _ typeName: String, _ fields: [Expr.StructField]) -> Expr {
    .struct(id: newID(ctx), typeName: typeName, fields: fields)
  }

  func newObjectField(_ fieldID: Int64, _ field: String, _ value: Expr, _ optional: Bool)
    -> Expr.StructField
  {
    Expr.StructField(id: fieldID, name: field, value: value, isOptional: optional)
  }

  func newID(_ ctx: IDSource) -> Int64 {
    if case .id(let id) = ctx {
      return id
    }
    return id(ctx)
  }

  func newExpr(_ ctx: IDSource) -> Expr {
    .unspecified(id: newID(ctx))
  }

  /// Allocates a new id and records the offset range of `ctx`; -1 when `ctx` is nil.
  func id(_ ctx: IDSource) -> Int64 {
    var offset = OffsetRange(start: 0, stop: 0)
    switch ctx {
    case .context(let c):
      guard let c, let start = c.start else {
        return -1
      }
      offset.start = sourceInfo.computeOffset(line: Int32(start.line), column: Int32(start.column))
      offset.stop = offset.start + Int32(c.text.utf8.count)
    case .token(let t):
      guard let t else {
        return -1
      }
      offset.start = sourceInfo.computeOffset(line: Int32(t.line), column: Int32(t.column))
      offset.stop = offset.start + Int32(t.text.utf8.count)
    case .location(let l):
      offset.start = sourceInfo.computeOffsetAbsolute(line: Int32(l.line), column: Int32(l.column))
      offset.stop = offset.start
    case .offsetRange(let r):
      offset = r
    case .id:
      return -1
    }
    let id = nextID
    sourceInfo.setOffsetRange(id, offset)
    nextID += 1
    return id
  }

  func deleteID(_ id: Int64) {
    sourceInfo.clearOffsetRange(id)
    if id == nextID - 1 {
      nextID -= 1
    }
  }

  func location(_ id: Int64) -> Location {
    sourceInfo.startLocation(id)
  }

  func location(ofOffset offset: Int32) -> Location {
    sourceInfo.location(ofOffset: offset)
  }

  /// Replaces nested macro expansions in a macro call argument with references to their ids.
  func buildMacroCallArg(_ expr: Expr) -> Expr {
    if sourceInfo.macroCall(expr.id) != nil {
      return .unspecified(id: expr.id)
    }
    switch expr.kind {
    case .call(let call):
      let macroArgs = call.args.map { buildMacroCallArg($0) }
      guard let target = call.target else {
        return .call(id: expr.id, function: call.function, args: macroArgs)
      }
      let macroTarget = buildMacroCallArg(target)
      return .memberCall(id: expr.id, function: call.function, target: macroTarget, args: macroArgs)
    case .list(let list):
      let macroListArgs = list.elements.map { buildMacroCallArg($0) }
      return .list(id: expr.id, elements: macroListArgs, optionalIndices: list.optionalIndices)
    default:
      return expr
    }
  }

  /// Records the original call of a macro expanded into `exprID`.
  func addMacroCall(_ exprID: Int64, _ function: String, _ target: Expr?, _ args: [Expr]) {
    let macroArgs = args.map { buildMacroCallArg($0) }
    guard let target else {
      sourceInfo.setMacroCall(exprID, .call(id: 0, function: function, args: macroArgs))
      return
    }
    let macroTarget: Expr
    if sourceInfo.macroCall(target.id) != nil {
      macroTarget = .unspecified(id: target.id)
    } else {
      macroTarget = buildMacroCallArg(target)
    }
    sourceInfo.setMacroCall(
      exprID, .memberCall(id: 0, function: function, target: macroTarget, args: macroArgs))
  }
}

/// Builds `&&` / `||` chains either as balanced binary trees or as one variadic call
/// (cel-go `logicManager`).
struct LogicManager {
  let function: String
  var terms: [Expr]
  var ops: [Int64] = []
  let variadicASTs: Bool

  init(function: String, term: Expr, variadic: Bool) {
    self.function = function
    self.terms = [term]
    self.variadicASTs = variadic
  }

  mutating func addTerm(_ op: Int64, _ term: Expr) {
    terms.append(term)
    ops.append(op)
  }

  func toExpr() -> Expr {
    if terms.count == 1 {
      return terms[0]
    }
    if variadicASTs {
      return .call(id: ops[0], function: function, args: terms)
    }
    return balancedTree(0, ops.count - 1)
  }

  private func balancedTree(_ lo: Int, _ hi: Int) -> Expr {
    let mid = (lo + hi + 1) / 2
    let left = mid == lo ? terms[mid] : balancedTree(lo, mid - 1)
    let right = mid == hi ? terms[mid + 1] : balancedTree(mid + 1, hi)
    return .call(id: ops[mid], function: function, args: [left, right])
  }
}

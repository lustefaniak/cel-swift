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
//
// Ported from cel-go interpreter/prune.go.

/// Prunes an expression with the values recorded during an evaluation, producing the residual AST
/// (cel-go `PruneAst`).
///
/// Typical uses: evaluate with unknowns, and if the result is unknown, prune and evaluate the residual
/// once more data is known, so known function results are not recomputed; or evaluate once and prune to
/// constant-fold an expression. Sub-expressions with a known value become literals; `&&`, `||`, `?:`,
/// `in` and `!` with known operands are simplified.
package func pruneAST(_ expr: Expr, macroCalls: [Int64: Expr], state: any EvalState) -> AST {
  let pruneState = EvalStateRecorder()
  for id in state.ids {
    pruneState.setValue(id, state.value(id))
  }
  let pruner = ASTPruner(macroCalls: macroCalls, state: pruneState, nextExprID: maxExprID(expr))
  var newExpr = expr
  withStack(depth: expr.depth) {
    newExpr = pruner.prune(expr).0
  }
  var info = SourceInfo(source: nil)
  for (id, call) in pruner.macroCalls {
    info.setMacroCall(id, call)
  }
  return AST(expr: newExpr, sourceInfo: info)
}

/// One more than the largest id in the expression (cel-go `getMaxID`).
private func maxExprID(_ expr: Expr) -> Int64 {
  var maxID: Int64 = 1
  expr.preOrderVisit(
    expr: { if $0.id >= maxID { maxID = $0.id + 1 } },
    entry: { if $0.id >= maxID { maxID = $0.id + 1 } })
  return maxID
}

private final class ASTPruner {
  var macroCalls: [Int64: Expr]
  let state: EvalStateRecorder
  var nextExprID: Int64

  init(macroCalls: [Int64: Expr], state: EvalStateRecorder, nextExprID: Int64) {
    self.macroCalls = macroCalls
    self.state = state
    self.nextExprID = nextExprID
  }

  func nextID() -> Int64 {
    defer { nextExprID += 1 }
    return nextExprID
  }

  /// The observed value of an id, including unknowns and errors.
  func value(_ id: Int64) -> Value? {
    state.value(id)
  }

  /// The observed value of an id, if it is neither unknown nor an error.
  func maybeValue(_ id: Int64) -> Value? {
    guard let v = state.value(id), !v.isUnknownOrError else {
      return nil
    }
    return v
  }

  /// A literal expression for a value, if it can be written as one (cel-go `maybeCreateLiteral`).
  ///
  /// cel-go writes optionals as literals of an optional constant; `Constant` has no optional case,
  /// so they become `optional.of(x)` / `optional.none()` calls.
  func maybeCreateLiteral(_ id: Int64, _ val: Value) -> Expr? {
    switch val {
    case .bool(let b):
      state.setValue(id, val)
      return .literal(id: id, .bool(b))
    case .bytes(let b):
      state.setValue(id, val)
      return .literal(id: id, .bytes(b))
    case .double(let d):
      state.setValue(id, val)
      return .literal(id: id, .double(d))
    case .int(let i):
      state.setValue(id, val)
      return .literal(id: id, .int(i))
    case .null:
      state.setValue(id, val)
      return .literal(id: id, .null)
    case .string(let s):
      state.setValue(id, val)
      return .literal(id: id, .string(s))
    case .uint(let u):
      state.setValue(id, val)
      return .literal(id: id, .uint(u))
    case .optional(let inner):
      guard let inner else {
        state.setValue(id, val)
        return .call(id: id, function: OptionalLibrary.optionalNoneFunc, args: [])
      }
      guard let arg = maybeCreateLiteral(nextID(), inner) else {
        return nil
      }
      state.setValue(id, val)
      return .call(id: id, function: OptionalLibrary.optionalOfFunc, args: [arg])
    case .duration:
      state.setValue(id, val)
      guard case .string(let s) = val.convert(to: .string) else { return nil }
      return .call(
        id: id, function: Overloads.typeConvertDuration, args: [.literal(id: nextID(), .string(s))])
    case .timestamp:
      guard case .string(let s) = val.convert(to: .string) else { return nil }
      return .call(
        id: id, function: Overloads.typeConvertTimestamp, args: [.literal(id: nextID(), .string(s))])
    case .list(let list):
      var elems: [Expr] = []
      elems.reserveCapacity(list.count)
      for i in 0..<list.count {
        let elem = list.element(at: i)
        if elem.isUnknownOrError {
          return nil
        }
        guard let e = maybeCreateLiteral(nextID(), elem) else {
          return nil
        }
        elems.append(e)
      }
      state.setValue(id, val)
      return .list(id: id, elements: elems)
    case .map(let map):
      var entries: [Expr.MapEntry] = []
      var complete = true
      map.forEachKey { key in
        let k = key.value
        let v = map.value(forKey: key) ?? .null
        if v.isUnknownOrError {
          complete = false
          return false
        }
        guard let keyExpr = maybeCreateLiteral(nextID(), k), let valExpr = maybeCreateLiteral(nextID(), v)
        else {
          complete = false
          return false
        }
        entries.append(Expr.MapEntry(id: nextID(), key: keyExpr, value: valExpr))
        return true
      }
      if !complete {
        return nil
      }
      state.setValue(id, val)
      return .map(id: id, entries: entries)
    default:
      // Message literals would need the provider to enumerate fields (cel-go issues/377).
      return nil
    }
  }

  /// An optional list element: dropped if none, a literal if its value is known (cel-go
  /// `maybePruneOptional`). Returns the element (nil when dropped) and whether it was pruned.
  func maybePruneOptional(_ elem: Expr) -> (Expr?, Bool) {
    if let elemVal = value(elem.id), case .optional(let inner) = elemVal {
      guard let inner else {
        return (nil, true)
      }
      if let newElem = maybeCreateLiteral(elem.id, inner) {
        return (newElem, true)
      }
    }
    return (elem, false)
  }

  func maybePruneIn(_ id: Int64, _ call: Expr.Call) -> Expr? {
    guard let val = maybeValue(call.args[1].id) else { return nil }
    if case .int(0) = val.size() {
      return maybeCreateLiteral(id, .bool(false))
    }
    return nil
  }

  func maybePruneLogicalNot(_ id: Int64, _ call: Expr.Call) -> Expr? {
    guard let val = maybeValue(call.args[0].id), case .bool(let b) = val else { return nil }
    return maybeCreateLiteral(id, .bool(!b))
  }

  /// The result is unknown, so at least one side is; a known side can be dropped.
  func maybePruneOr(_ id: Int64, _ call: Expr.Call) -> Expr? {
    if let v = maybeValue(call.args[0].id) {
      if v == .bool(true) {
        return maybeCreateLiteral(id, .bool(true))
      }
      return call.args[1]
    }
    if let v = maybeValue(call.args[1].id) {
      if v == .bool(true) {
        return maybeCreateLiteral(id, .bool(true))
      }
      return call.args[0]
    }
    return nil
  }

  func maybePruneAnd(_ id: Int64, _ call: Expr.Call) -> Expr? {
    if let v = maybeValue(call.args[0].id) {
      if v == .bool(false) {
        return maybeCreateLiteral(id, .bool(false))
      }
      return call.args[1]
    }
    if let v = maybeValue(call.args[1].id) {
      if v == .bool(false) {
        return maybeCreateLiteral(id, .bool(false))
      }
      return call.args[0]
    }
    return nil
  }

  func maybePruneConditional(_ call: Expr.Call) -> Expr? {
    guard let cond = maybeValue(call.args[0].id), case .bool(let c) = cond else { return nil }
    return c ? call.args[1] : call.args[2]
  }

  func maybePruneFunction(_ node: Expr, _ call: Expr.Call) -> Expr? {
    if value(node.id) == nil {
      return nil
    }
    switch call.function {
    case Operators.logicalOr where call.args.count == 2: return maybePruneOr(node.id, call)
    case Operators.logicalAnd where call.args.count == 2: return maybePruneAnd(node.id, call)
    case Operators.conditional: return maybePruneConditional(call)
    case Operators.in: return maybePruneIn(node.id, call)
    case Operators.logicalNot: return maybePruneLogicalNot(node.id, call)
    default: return nil
    }
  }

  /// Prunes a node; returns the new node and whether anything changed (cel-go `prune`).
  func prune(_ node: Expr) -> (Expr, Bool) {
    if let val = maybeValue(node.id), let newNode = maybeCreateLiteral(node.id, val) {
      macroCalls[node.id] = nil
      return (newNode, true)
    }
    if let macro = macroCalls[node.id] {
      var pruneMacroCall = !node.isUnspecified
      if case .comprehension = node.kind {
        // Only cel.bind() is pruned in terms of its macro call: the other comprehension variables
        // are visible, and state tracking only records their last iteration.
        pruneMacroCall = isCelBindMacro(macro)
      }
      if pruneMacroCall {
        let (newMacro, pruned) = prune(macro)
        if pruned {
          macroCalls[node.id] = newMacro
        }
      } else if let macroCall = macro.asCall, let target = macroCall.target {
        let (newTarget, pruned) = prune(target)
        if pruned {
          macroCalls[node.id] = .memberCall(
            id: macro.id, function: macroCall.function, target: newTarget, args: macroCall.args)
        }
      }
    }

    switch node.kind {
    case .select(let sel):
      let (operand, pruned) = prune(sel.operand)
      if pruned {
        if sel.testOnly {
          return (.presenceTest(id: node.id, operand: operand, field: sel.field), true)
        }
        return (.select(id: node.id, operand: operand, field: sel.field), true)
      }
    case .call(let call):
      var argsPruned = false
      var newArgs = call.args
      for i in newArgs.indices {
        let (arg, pruned) = prune(newArgs[i])
        if pruned {
          argsPruned = true
          newArgs[i] = arg
        }
      }
      guard let target = call.target else {
        let newCall = Expr.call(id: node.id, function: call.function, args: newArgs)
        if let pruned = maybePruneFunction(newCall, Expr.Call(function: call.function, args: newArgs)) {
          return (pruned, true)
        }
        return (newCall, argsPruned)
      }
      let (newTarget, targetPruned) = prune(target)
      let newCallNode = Expr.Call(function: call.function, target: newTarget, args: newArgs)
      let newCall = Expr(id: node.id, kind: .call(newCallNode))
      if let pruned = maybePruneFunction(newCall, newCallNode) {
        return (pruned, true)
      }
      return (newCall, targetPruned || argsPruned)
    case .list(let list):
      let optIndices = Set(list.optionalIndices)
      var newOptIndices: [Int32] = []
      var newElems: [Expr] = []
      var listPruned = false
      var prunedIdx: Int32 = 0
      for (i, elem) in list.elements.enumerated() {
        if optIndices.contains(Int32(i)) {
          let (newElem, pruned) = maybePruneOptional(elem)
          if pruned {
            listPruned = true
            if let newElem {
              newElems.append(newElem)
              prunedIdx += 1
            }
            continue
          }
          newOptIndices.append(prunedIdx)
        }
        let (newElem, pruned) = prune(elem)
        listPruned = listPruned || pruned
        newElems.append(newElem)
        prunedIdx += 1
      }
      if listPruned {
        return (.list(id: node.id, elements: newElems, optionalIndices: newOptIndices.sorted()), true)
      }
    case .map(let map):
      var mapPruned = false
      var newEntries = map.entries
      for i in newEntries.indices {
        let entry = newEntries[i]
        let (newKey, keyPruned) = prune(entry.key)
        let (newValue, valuePruned) = prune(entry.value)
        if !keyPruned && !valuePruned {
          continue
        }
        mapPruned = true
        newEntries[i] = Expr.MapEntry(id: entry.id, key: newKey, value: newValue, isOptional: entry.isOptional)
      }
      if mapPruned {
        return (.map(id: node.id, entries: newEntries), true)
      }
    case .struct(let obj):
      var structPruned = false
      var newFields = obj.fields
      for i in newFields.indices {
        let field = newFields[i]
        let (newValue, pruned) = prune(field.value)
        if !pruned {
          continue
        }
        structPruned = true
        newFields[i] = Expr.StructField(id: field.id, name: field.name, value: newValue, isOptional: field.isOptional)
      }
      if structPruned {
        return (.struct(id: node.id, typeName: obj.typeName, fields: newFields), true)
      }
    case .comprehension(var compre):
      // Only the range is pruned: state tracking records only the last iteration, so residuals of
      // the loop body could be inaccurate.
      let (newRange, pruned) = prune(compre.iterRange)
      if pruned {
        compre.iterRange = newRange
        return (Expr(id: node.id, kind: .comprehension(compre)), true)
      }
    case .unspecified, .literal, .ident:
      break
    }
    return (node, false)
  }
}

private func isCelBindMacro(_ macro: Expr) -> Bool {
  guard let call = macro.asCall, call.function == "bind", let target = call.target,
    target.asIdent == "cel"
  else {
    return false
  }
  return true
}

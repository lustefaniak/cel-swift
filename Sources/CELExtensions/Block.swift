// Copyright 2024 Google LLC
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
// Ported from cel-go ext/bindings.go (celBlockPlan, dynamicBlock, dynamicSlotActivation,
// constantBlock, constantSlotActivation, matchSlot): the planner decorator evaluating
// `cel.@block([slot0, slot1, ...], expr)`, where `expr` refers to the slots as `@index0`,
// `@index1`, ... and each slot is computed at most once per evaluation.
//
// cel-go pools the slot activations; here each evaluation allocates one.

import CEL

enum BlockPlan {
  /// The decorator replacing `cel.@block` calls with block nodes.
  static let decorator: ProgramDecorator = { i in
    guard let call = i as? any InterpretableCall, call.function == Library.blockFunction else {
      return i
    }
    let args = call.args
    if args.count != 2 {
      throw BlockPlanError(message: "cel.@block expects two arguments, but got \(args.count)")
    }
    let expr = args[1]
    if let block = args[0] as? any InterpretableConstructor {
      return DynamicBlock(slotExprs: block.initVals, expr: expr)
    }
    // A constant-valued block, which can happen after constant folding.
    if let constant = args[0] as? any InterpretableConst, case .list(let slots) = constant.value {
      if slots.count == 0 {
        return expr
      }
      return ConstantBlock(slots: slots, expr: expr)
    }
    throw BlockPlanError(message: "cel.@block expects a list constructor as the first argument")
  }
}

struct BlockPlanError: Error, CustomStringConvertible {
  let message: String
  var description: String { message }
}

/// Port of `matchSlot`: the slot index named by `@index<N>`, if it is in range.
private func matchSlot(_ name: String, _ slotCount: Int) -> Int? {
  let prefix = "@index"
  guard name.utf8.starts(with: prefix.utf8) else { return nil }
  let digits = String(decoding: name.utf8.dropFirst(prefix.utf8.count), as: UTF8.self)
  // strconv.Atoi accepts an optional sign.
  guard let idx = Int(digits), idx >= 0, idx < slotCount else { return nil }
  return idx
}

final class DynamicBlock: Interpretable {
  let slotExprs: [any Interpretable]
  let expr: any Interpretable

  init(slotExprs: [any Interpretable], expr: any Interpretable) {
    self.slotExprs = slotExprs
    self.expr = expr
  }

  var id: Int64 { expr.id }

  func eval(_ frame: ExecutionFrame) -> Value {
    let slots = DynamicSlotActivation(activation: frame.activation, slotExprs: slotExprs)
    let child = frame.push(slots)
    slots.frame = child
    return expr.eval(child)
  }
}

/// Resolves `@index<N>` by evaluating slot N on first use; other names go to the enclosing
/// activation.
private final class DynamicSlotActivation: Activation {
  let activation: any Activation
  let slotExprs: [any Interpretable]
  var frame: ExecutionFrame?
  private var values: [Value?]
  private var visited: [Bool]

  init(activation: any Activation, slotExprs: [any Interpretable]) {
    self.activation = activation
    self.slotExprs = slotExprs
    self.values = Array(repeating: nil, count: slotExprs.count)
    self.visited = Array(repeating: false, count: slotExprs.count)
  }

  func resolveName(_ name: String) -> Value? {
    if let idx = matchSlot(name, slotExprs.count), let frame {
      if visited[idx] {
        // Not found when the slot refers to itself.
        return values[idx]
      }
      visited[idx] = true
      let val = slotExprs[idx].eval(frame)
      values[idx] = val
      return val
    }
    return activation.resolveName(name)
  }

  var parent: (any Activation)? { activation.parent }
  var unwrapped: (any Activation)? { activation }
  func isLocalVariable(_ name: String) -> Bool { activation.isLocalVariable(name) }
  func asPartialActivation() -> (any PartialActivation)? { activation.asPartialActivation() }
}

final class ConstantBlock: Interpretable {
  let slots: any ListValue
  let expr: any Interpretable

  init(slots: any ListValue, expr: any Interpretable) {
    self.slots = slots
    self.expr = expr
  }

  var id: Int64 { expr.id }

  func eval(_ frame: ExecutionFrame) -> Value {
    expr.eval(frame.push(ConstantSlotActivation(activation: frame.activation, slots: slots)))
  }
}

private struct ConstantSlotActivation: Activation {
  let activation: any Activation
  let slots: any ListValue

  func resolveName(_ name: String) -> Value? {
    if let idx = matchSlot(name, slots.count) {
      return slots.element(at: idx)
    }
    return activation.resolveName(name)
  }

  var parent: (any Activation)? { activation.parent }
  var unwrapped: (any Activation)? { activation }
  func isLocalVariable(_ name: String) -> Bool { activation.isLocalVariable(name) }
  func asPartialActivation() -> (any PartialActivation)? { activation.asPartialActivation() }
}

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

// Ported from cel-go ext/extension_option_factory.go (ExtensionOptionFactory, the names config
// files use for extensions) and the `cel.@block` planning of ext/bindings.go (dynamicBlock,
// constantBlock, dynamicSlotActivation).
//
// STAND-IN: `Library.bindings` in CELExtensions declares `cel.@block` but leaves its evaluation to
// the interpreter, which does not recognize it yet. Until it does, the policy package attaches the
// planner decorator below to the bindings library it resolves. Remove `BlockEvaluation` once the
// interpreter (or the bindings library) evaluates `cel.@block`.

import CEL
import CELExtensions

/// The extension libraries a policy environment config can name (cel-go
/// `ext.ExtensionOptionFactory`).
enum PolicyExtensions {
  static let aliases: [String: String] = [
    "bindings": "cel.lib.ext.cel.bindings",
    "encoders": "cel.lib.ext.encoders",
    "lists": "cel.lib.ext.lists",
    "math": "cel.lib.ext.math",
    "protos": "cel.lib.ext.protos",
    "sets": "cel.lib.ext.sets",
    "strings": "cel.lib.ext.strings",
    "two-var-comprehensions": "cel.lib.ext.comprev2",
    "regex": "cel.lib.ext.regex",
  ]

  static func resolve(_ name: String, version: UInt32) -> Library? {
    switch aliases[name] ?? name {
    case "cel.lib.ext.cel.bindings":
      var lib = Library.bindings(version: version)
      if version >= 1 {
        lib.decorators.append({ i in try BlockEvaluation.plan(i) })
      }
      return lib
    case "cel.lib.ext.encoders": return .encoders(version: version)
    case "cel.lib.ext.lists": return .lists(version: version)
    case "cel.lib.ext.math": return .math(version: version)
    case "cel.lib.ext.protos": return .protos(version: version)
    case "cel.lib.ext.sets": return .sets(version: version)
    case "cel.lib.ext.strings": return .strings(version: version)
    case "cel.lib.ext.comprev2": return .twoVarComprehensions(version: version)
    case "cel.lib.ext.regex": return .regex(version: version)
    default: return nil
    }
  }
}

/// Plans `cel.@block([slots...], expr)` calls (cel-go `celBindings.ProgramOptions`).
enum BlockEvaluation {
  static let blockFunction = "cel.@block"
  static let indexPrefix = "@index"

  static func plan(_ i: any Interpretable) throws -> any Interpretable {
    guard let call = i as? any InterpretableCall, call.function == blockFunction else {
      return i
    }
    let args = call.args
    guard args.count == 2 else {
      throw PlanError("cel.@block expects two arguments, but got \(args.count)")
    }
    if let block = args[0] as? any InterpretableConstructor {
      return DynamicBlock(slots: block.initVals, expr: args[1])
    }
    if let constant = args[0] as? any InterpretableConst, case .list(let l) = constant.value {
      if l.count == 0 {
        return args[1]
      }
      let slots = (0..<l.count).map { EvalConstSlot(id: 0, value: l.element(at: $0)) }
      return DynamicBlock(slots: slots, expr: args[1])
    }
    throw PlanError("cel.@block expects a list constructor as the first argument")
  }
}

/// A constant slot value.
final class EvalConstSlot: Interpretable {
  let id: Int64
  let value: Value

  init(id: Int64, value: Value) {
    self.id = id
    self.value = value
  }

  func eval(_ frame: ExecutionFrame) -> Value { value }
}

/// Evaluates `expr` with `@index<N>` bound lazily to the slot expressions, each computed at most
/// once per evaluation (cel-go `dynamicBlock`).
final class DynamicBlock: Interpretable {
  let slots: [any Interpretable]
  let expr: any Interpretable

  init(slots: [any Interpretable], expr: any Interpretable) {
    self.slots = slots
    self.expr = expr
  }

  var id: Int64 { expr.id }

  func eval(_ frame: ExecutionFrame) -> Value {
    let activation = SlotActivation(slots: slots, parentFrame: frame)
    let blockFrame = frame.push(activation)
    activation.frame = blockFrame
    return expr.eval(blockFrame)
  }
}

/// The slot memory of one block evaluation (cel-go `dynamicSlotActivation`).
final class SlotActivation: Activation {
  let slots: [any Interpretable]
  let parentFrame: ExecutionFrame
  weak var frame: ExecutionFrame?
  private var values: [Value?]
  private var visited: [Bool]

  init(slots: [any Interpretable], parentFrame: ExecutionFrame) {
    self.slots = slots
    self.parentFrame = parentFrame
    self.values = Array(repeating: nil, count: slots.count)
    self.visited = Array(repeating: false, count: slots.count)
  }

  func resolveName(_ name: String) -> Value? {
    if let idx = matchSlot(name) {
      if visited[idx] {
        // A slot referring to itself resolves to not found.
        return values[idx]
      }
      visited[idx] = true
      let value = slots[idx].eval(frame ?? parentFrame)
      values[idx] = value
      return value
    }
    return parentFrame.resolveName(name)
  }

  var parent: (any Activation)? { parentFrame }

  var unwrapped: (any Activation)? { parentFrame }

  func asPartialActivation() -> (any PartialActivation)? {
    parentFrame.asPartialActivation()
  }

  private func matchSlot(_ name: String) -> Int? {
    let prefix = BlockEvaluation.indexPrefix.utf8
    guard name.utf8.starts(with: prefix) else {
      return nil
    }
    let digits = name.utf8.dropFirst(prefix.count)
    guard !digits.isEmpty, digits.allSatisfy({ $0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9") }),
      let idx = Int(String(decoding: digits, as: UTF8.self)), idx < slots.count
    else {
      return nil
    }
    return idx
  }
}

// Copyright 2019 Google LLC
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
// Ported from cel-go interpreter/interpretable.go.
//
// cel-go has two evaluation entry points (`Eval(Activation)` and `Exec(*ExecutionFrame)`); here there
// is one, `eval(_ frame:)`, and `evaluate(_ activation:)` wraps an activation in a fresh frame.
// Interpretables are immutable final classes, so a planned program is `Sendable`.

/// A planned expression node that evaluates to a value (cel-go `Interpretable` / `InterpretableV2`).
package protocol Interpretable: AnyObject, Sendable {
  /// The id of the expression node.
  var id: Int64 { get }

  /// Evaluates the node in a frame.
  func eval(_ frame: ExecutionFrame) -> Value
}

extension Interpretable {
  /// Evaluates the node with an activation in a new frame (cel-go `Eval`).
  package func evaluate(_ activation: any Activation) -> Value {
    if let frame = activation as? ExecutionFrame {
      return eval(frame)
    }
    return eval(ExecutionFrame(activation))
  }
}

/// A constant node (cel-go `InterpretableConst`).
package protocol InterpretableConst: Interpretable {
  var value: Value { get }
}

/// A node resolving an attribute (cel-go `InterpretableAttribute`). It is also an attribute, so it
/// can be used as a qualifier of another attribute (`a[b]`).
package protocol InterpretableAttribute: Interpretable, Attribute {
  /// The underlying attribute.
  var attr: any Attribute { get }

  /// The node with a qualifier appended to its attribute.
  func withQualifier(_ qualifier: any Qualifier) throws -> any InterpretableAttribute
}

extension InterpretableAttribute {
  package func addingQualifier(_ qualifier: any Qualifier) throws -> any Attribute {
    try withQualifier(qualifier)
  }
}

/// A function call node (cel-go `InterpretableCall`).
package protocol InterpretableCall: Interpretable {
  /// The function name, or the operator's mangled name (`_+_`).
  var function: String { get }
  /// The overload id, or the empty string when not resolved by the checker.
  var overloadID: String { get }
  /// The arguments; for receiver-style calls the receiver is the first.
  var args: [any Interpretable] { get }
}

/// A list, map or struct construction node (cel-go `InterpretableConstructor`).
package protocol InterpretableConstructor: Interpretable {
  /// The list elements, the map keys and values interleaved, or the struct field values.
  var initVals: [any Interpretable] { get }
  /// The constructed type: `list`, `map` or the struct type.
  var constructedType: CELType { get }
}

// MARK: - Constants and logic

/// A constant value (cel-go `evalConst`).
package final class EvalConst: InterpretableConst {
  package let id: Int64
  package let value: Value

  package init(id: Int64, value: Value) {
    self.id = id
    self.value = value
  }

  package func eval(_ frame: ExecutionFrame) -> Value {
    value
  }
}

/// Logical or: `true` absorbs errors and unknowns in any position; otherwise unknowns win over
/// errors (cel-go `evalOr`).
final class EvalOr: Interpretable {
  let id: Int64
  let terms: [any Interpretable]

  init(id: Int64, terms: [any Interpretable]) {
    self.id = id
    self.terms = terms
  }

  func eval(_ frame: ExecutionFrame) -> Value {
    var err: Value?
    var unknown: UnknownSet?
    for term in terms {
      let val = term.eval(frame)
      if case .bool(let b) = val {
        if b { return .bool(true) }
        continue
      }
      let isUnknown: Bool
      (unknown, isUnknown) = Value.maybeMergeUnknowns(val, unknown)
      if !isUnknown && err == nil {
        err = Value.maybeNoSuchOverload(val).labellingError(with: id)
      }
    }
    if let unknown { return .unknown(unknown) }
    if let err { return err }
    return .bool(false)
  }
}

/// Logical and: `false` absorbs errors and unknowns in any position (cel-go `evalAnd`).
final class EvalAnd: Interpretable {
  let id: Int64
  let terms: [any Interpretable]

  init(id: Int64, terms: [any Interpretable]) {
    self.id = id
    self.terms = terms
  }

  func eval(_ frame: ExecutionFrame) -> Value {
    var err: Value?
    var unknown: UnknownSet?
    for term in terms {
      let val = term.eval(frame)
      if case .bool(let b) = val {
        if !b { return .bool(false) }
        continue
      }
      let isUnknown: Bool
      (unknown, isUnknown) = Value.maybeMergeUnknowns(val, unknown)
      if !isUnknown && err == nil {
        err = Value.maybeNoSuchOverload(val).labellingError(with: id)
      }
    }
    if let unknown { return .unknown(unknown) }
    if let err { return err }
    return .bool(true)
  }
}

/// Strict equality checks shared by `==` and `!=` (cel-go `evalEq` / `evalNe`): the first error
/// wins, then merged unknowns.
@inline(__always)
private func strictPair(_ lhs: any Interpretable, _ rhs: any Interpretable, _ frame: ExecutionFrame)
  -> (Value, Value, Value?)
{
  let lVal = lhs.eval(frame)
  if case .error = lVal { return (lVal, lVal, lVal) }
  let rVal = rhs.eval(frame)
  if case .error = rVal { return (lVal, rVal, rVal) }
  var unknown: UnknownSet?
  (unknown, _) = Value.maybeMergeUnknowns(lVal, unknown)
  (unknown, _) = Value.maybeMergeUnknowns(rVal, unknown)
  if let unknown { return (lVal, rVal, .unknown(unknown)) }
  return (lVal, rVal, nil)
}

/// `==` (cel-go `evalEq`).
final class EvalEq: InterpretableCall {
  let id: Int64
  let lhs: any Interpretable
  let rhs: any Interpretable

  init(id: Int64, lhs: any Interpretable, rhs: any Interpretable) {
    self.id = id
    self.lhs = lhs
    self.rhs = rhs
  }

  var function: String { Operators.equals }
  var overloadID: String { Overloads.equals }
  var args: [any Interpretable] { [lhs, rhs] }

  func eval(_ frame: ExecutionFrame) -> Value {
    let (l, r, early) = strictPair(lhs, rhs, frame)
    if let early { return early }
    return l.celEquals(r)
  }
}

/// `!=` (cel-go `evalNe`).
final class EvalNe: InterpretableCall {
  let id: Int64
  let lhs: any Interpretable
  let rhs: any Interpretable

  init(id: Int64, lhs: any Interpretable, rhs: any Interpretable) {
    self.id = id
    self.lhs = lhs
    self.rhs = rhs
  }

  var function: String { Operators.notEquals }
  var overloadID: String { Overloads.notEquals }
  var args: [any Interpretable] { [lhs, rhs] }

  func eval(_ frame: ExecutionFrame) -> Value {
    let (l, r, early) = strictPair(lhs, rhs, frame)
    if let early { return early }
    if case .bool(true) = l.celEquals(r) {
      return .bool(false)
    }
    return .bool(true)
  }
}

// MARK: - Function calls

/// Whether the implementation applies to the first argument (cel-go's trait test in `evalUnary` & co).
@inline(__always)
private func implApplies(_ trait: TypeTraits, _ strict: Bool, _ arg0: Value) -> Bool {
  trait.isEmpty || (!strict && arg0.isUnknownOrError) || arg0.traits.isSuperset(of: trait)
}

/// A call without arguments (cel-go `evalZeroArity`).
final class EvalZeroArity: InterpretableCall {
  let id: Int64
  let function: String
  let overloadID: String
  let impl: FunctionBinding.Variadic

  init(id: Int64, function: String, overloadID: String, impl: @escaping FunctionBinding.Variadic) {
    self.id = id
    self.function = function
    self.overloadID = overloadID
    self.impl = impl
  }

  var args: [any Interpretable] { [] }

  func eval(_ frame: ExecutionFrame) -> Value {
    impl([]).labellingError(with: id)
  }
}

/// A one-argument call (cel-go `evalUnary`).
final class EvalUnary: InterpretableCall {
  let id: Int64
  let function: String
  let overloadID: String
  let arg: any Interpretable
  let trait: TypeTraits
  let impl: FunctionBinding.Unary?
  let nonStrict: Bool

  init(
    id: Int64, function: String, overloadID: String, arg: any Interpretable, trait: TypeTraits,
    impl: FunctionBinding.Unary?, nonStrict: Bool
  ) {
    self.id = id
    self.function = function
    self.overloadID = overloadID
    self.arg = arg
    self.trait = trait
    self.impl = impl
    self.nonStrict = nonStrict
  }

  var args: [any Interpretable] { [arg] }

  func eval(_ frame: ExecutionFrame) -> Value {
    let argVal = arg.eval(frame)
    let strict = !nonStrict
    if strict && argVal.isUnknownOrError {
      return argVal
    }
    if let impl, implApplies(trait, strict, argVal) {
      return impl(argVal).labellingError(with: id)
    }
    if argVal.traits.contains(.receiver) {
      return argVal.receive(function: function, overload: overloadID, args: []).labellingError(with: id)
    }
    return .error(EvalError("no such overload: \(function)", exprID: id))
  }
}

/// A two-argument call (cel-go `evalBinary`).
final class EvalBinary: InterpretableCall {
  let id: Int64
  let function: String
  let overloadID: String
  let lhs: any Interpretable
  let rhs: any Interpretable
  let trait: TypeTraits
  let impl: FunctionBinding.Binary?
  let nonStrict: Bool

  init(
    id: Int64, function: String, overloadID: String, lhs: any Interpretable, rhs: any Interpretable,
    trait: TypeTraits, impl: FunctionBinding.Binary?, nonStrict: Bool
  ) {
    self.id = id
    self.function = function
    self.overloadID = overloadID
    self.lhs = lhs
    self.rhs = rhs
    self.trait = trait
    self.impl = impl
    self.nonStrict = nonStrict
  }

  var args: [any Interpretable] { [lhs, rhs] }

  func eval(_ frame: ExecutionFrame) -> Value {
    let lVal = lhs.eval(frame)
    let strict = !nonStrict
    if strict, case .error = lVal {
      return lVal
    }
    let rVal = rhs.eval(frame)
    if strict {
      if case .error = rVal {
        return rVal
      }
      var unknown: UnknownSet?
      (unknown, _) = Value.maybeMergeUnknowns(lVal, unknown)
      (unknown, _) = Value.maybeMergeUnknowns(rVal, unknown)
      if let unknown {
        return .unknown(unknown)
      }
    }
    if let impl, implApplies(trait, strict, lVal) {
      return impl(lVal, rVal).labellingError(with: id)
    }
    if lVal.traits.contains(.receiver) {
      return lVal.receive(function: function, overload: overloadID, args: [rVal]).labellingError(with: id)
    }
    return .error(EvalError("no such overload: \(function)", exprID: id))
  }
}

/// A call with any number of arguments (cel-go `evalVarArgs`).
final class EvalVarArgs: InterpretableCall {
  let id: Int64
  let function: String
  let overloadID: String
  let args: [any Interpretable]
  let trait: TypeTraits
  let impl: FunctionBinding.Variadic?
  let nonStrict: Bool

  init(
    id: Int64, function: String, overloadID: String, args: [any Interpretable], trait: TypeTraits,
    impl: FunctionBinding.Variadic?, nonStrict: Bool
  ) {
    self.id = id
    self.function = function
    self.overloadID = overloadID
    self.args = args
    self.trait = trait
    self.impl = impl
    self.nonStrict = nonStrict
  }

  func eval(_ frame: ExecutionFrame) -> Value {
    var argVals: [Value] = []
    argVals.reserveCapacity(args.count)
    let strict = !nonStrict
    var unknown: UnknownSet?
    for arg in args {
      let v = arg.eval(frame)
      if strict {
        if case .error = v {
          return v
        }
        (unknown, _) = Value.maybeMergeUnknowns(v, unknown)
      }
      argVals.append(v)
    }
    if strict, let unknown {
      return .unknown(unknown)
    }
    guard let arg0 = argVals.first else {
      return .error(EvalError("no such overload: \(function) \(id)", exprID: id))
    }
    if let impl, implApplies(trait, strict, arg0) {
      return impl(argVals).labellingError(with: id)
    }
    if arg0.traits.contains(.receiver) {
      return arg0.receive(function: function, overload: overloadID, args: Array(argVals.dropFirst()))
        .labellingError(with: id)
    }
    return .error(EvalError("no such overload: \(function) \(id)", exprID: id))
  }
}

// MARK: - Constructors

private func invalidOptionalElementInit(_ value: Value) -> Value {
  .error(message: "cannot initialize optional list element from non-optional value \(formatGoValue(value))")
}

private func invalidOptionalEntryInit(_ field: String, _ value: Value) -> Value {
  .error(message: "cannot initialize optional entry '\(field)' from non-optional value \(formatGoValue(value))")
}

/// A list literal (cel-go `evalList`).
final class EvalList: InterpretableConstructor {
  let id: Int64
  let elems: [any Interpretable]
  let optionals: [Bool]
  let hasOptionals: Bool

  init(id: Int64, elems: [any Interpretable], optionals: [Bool], hasOptionals: Bool) {
    self.id = id
    self.elems = elems
    self.optionals = optionals
    self.hasOptionals = hasOptionals
  }

  var initVals: [any Interpretable] { elems }
  var constructedType: CELType { .listOfDyn }

  func eval(_ frame: ExecutionFrame) -> Value {
    var elemVals: [Value] = []
    elemVals.reserveCapacity(elems.count)
    var unknown: UnknownSet?
    for (i, elem) in elems.enumerated() {
      var elemVal = elem.eval(frame)
      if case .error = elemVal {
        return elemVal
      }
      (unknown, _) = Value.maybeMergeUnknowns(elemVal, unknown)
      if hasOptionals && optionals[i] && !elemVal.isUnknown {
        guard case .optional(let opt) = elemVal else {
          return invalidOptionalElementInit(elemVal).labellingError(with: id)
        }
        guard let opt else {
          continue
        }
        elemVal = opt
      }
      elemVals.append(elemVal)
    }
    if let unknown {
      return .unknown(unknown)
    }
    return .list(ArrayList(elemVals))
  }
}

/// A map literal (cel-go `evalMap`).
///
/// cel-go accepts any key value and lets a repeated key overwrite the earlier entry; the spec makes
/// both an error, and `MapKey` cannot hold other key types, so here they are errors
/// (docs/divergences.md).
final class EvalMap: InterpretableConstructor {
  let id: Int64
  let keys: [any Interpretable]
  let vals: [any Interpretable]
  let optionals: [Bool]
  let hasOptionals: Bool

  init(id: Int64, keys: [any Interpretable], vals: [any Interpretable], optionals: [Bool], hasOptionals: Bool) {
    self.id = id
    self.keys = keys
    self.vals = vals
    self.optionals = optionals
    self.hasOptionals = hasOptionals
  }

  var initVals: [any Interpretable] {
    var result: [any Interpretable] = []
    for (k, v) in zip(keys, vals) {
      result.append(k)
      result.append(v)
    }
    return result
  }

  var constructedType: CELType { .mapOfDyn }

  func eval(_ frame: ExecutionFrame) -> Value {
    var entries = OrderedMap()
    var unknown: UnknownSet?
    var keyError: Value?
    for i in keys.indices {
      let keyVal = keys[i].eval(frame)
      if case .error = keyVal {
        return keyVal
      }
      (unknown, _) = Value.maybeMergeUnknowns(keyVal, unknown)
      var valVal = vals[i].eval(frame)
      if case .error = valVal {
        return valVal
      }
      (unknown, _) = Value.maybeMergeUnknowns(valVal, unknown)
      var isNone = false
      if hasOptionals && optionals[i] && !valVal.isUnknown {
        guard case .optional(let opt) = valVal else {
          return invalidOptionalEntryInit(formatGoValue(keyVal), valVal).labellingError(with: id)
        }
        if let opt {
          valVal = opt
        } else {
          isNone = true
        }
      }
      if unknown != nil || keyError != nil {
        continue
      }
      guard let key = MapKey(keyVal) else {
        keyError = Value.error(EvalError("unsupported key type: \(keyVal.runtimeTypeName)", exprID: id))
        continue
      }
      if isNone {
        entries[key] = nil
        continue
      }
      if entries.find(keyVal) != nil {
        keyError = Value.error(EvalError("Failed with repeated key: \(formatGoValue(keyVal))", exprID: id))
        continue
      }
      entries[key] = valVal
    }
    if let unknown {
      return .unknown(unknown)
    }
    if let keyError {
      return keyError
    }
    return .map(entries)
  }
}

/// A message literal, built by the type provider (cel-go `evalObj`).
final class EvalObj: InterpretableConstructor {
  let id: Int64
  let typeName: String
  let fields: [String]
  let vals: [any Interpretable]
  let optionals: [Bool]
  let hasOptionals: Bool
  let provider: any TypeProvider

  init(
    id: Int64, typeName: String, fields: [String], vals: [any Interpretable], optionals: [Bool],
    hasOptionals: Bool, provider: any TypeProvider
  ) {
    self.id = id
    self.typeName = typeName
    self.fields = fields
    self.vals = vals
    self.optionals = optionals
    self.hasOptionals = hasOptionals
    self.provider = provider
  }

  var initVals: [any Interpretable] { vals }
  var constructedType: CELType { .objectType(typeName) }

  func eval(_ frame: ExecutionFrame) -> Value {
    var fieldVals: [String: Value] = [:]
    var unknown: UnknownSet?
    for (i, field) in fields.enumerated() {
      var val = vals[i].eval(frame)
      if case .error = val {
        return val
      }
      (unknown, _) = Value.maybeMergeUnknowns(val, unknown)
      if hasOptionals && optionals[i] && !val.isUnknown {
        guard case .optional(let opt) = val else {
          return invalidOptionalEntryInit(field, val).labellingError(with: id)
        }
        guard let opt else {
          fieldVals[field] = nil
          continue
        }
        val = opt
      }
      fieldVals[field] = val
    }
    if let unknown {
      return .unknown(unknown)
    }
    return provider.newValue(typeName, fields: fieldVals).labellingError(with: id)
  }
}

// MARK: - Comprehensions

/// A comprehension (cel-go `evalFold`).
final class EvalFold: Interpretable {
  let id: Int64
  let accuVar: String
  let iterVar: String
  let iterVar2: String
  let iterRange: any Interpretable
  let accu: any Interpretable
  let cond: any Interpretable
  let step: any Interpretable
  let result: any Interpretable
  /// Evaluates every iteration regardless of the loop condition (exhaustive evaluation).
  let exhaustive: Bool
  /// Checks the interrupt every iteration.
  let interruptable: Bool

  init(
    id: Int64, accuVar: String, iterVar: String, iterVar2: String, iterRange: any Interpretable,
    accu: any Interpretable, cond: any Interpretable, step: any Interpretable, result: any Interpretable,
    exhaustive: Bool = false, interruptable: Bool = false
  ) {
    self.id = id
    self.accuVar = accuVar
    self.iterVar = iterVar
    self.iterVar2 = iterVar2
    self.iterRange = iterRange
    self.accu = accu
    self.cond = cond
    self.step = step
    self.result = result
    self.exhaustive = exhaustive
    self.interruptable = interruptable
  }

  /// A copy with the exhaustive or interruptable flag set (used by decorators).
  func with(exhaustive: Bool? = nil, interruptable: Bool? = nil) -> EvalFold {
    EvalFold(
      id: id, accuVar: accuVar, iterVar: iterVar, iterVar2: iterVar2, iterRange: iterRange, accu: accu,
      cond: cond, step: step, result: result, exhaustive: exhaustive ?? self.exhaustive,
      interruptable: interruptable ?? self.interruptable)
  }

  func eval(_ frame: ExecutionFrame) -> Value {
    let folder = Folder(fold: self, parentFrame: frame)
    let child = frame.push(folder)
    let foldRange = iterRange.eval(frame)
    if foldRange.isUnknownOrError {
      return foldRange
    }
    if !iterVar2.isEmpty {
      switch foldRange {
      case .map(let m):
        for key in m.keys where !folder.foldEntry(child, key.value, m.value(forKey: key) ?? .null) {
          break
        }
      case .list(let l):
        for i in 0..<l.count where !folder.foldEntry(child, .int(Int64(i)), l.element(at: i)) {
          break
        }
      default:
        return .error(
          EvalError("unsupported comprehension range type: \(goTypeName(foldRange))", exprID: id))
      }
      return folder.evalResult(child)
    }
    switch foldRange {
    case .list(let l):
      for i in 0..<l.count where !folder.foldStep(child, l.element(at: i)) {
        break
      }
    case .map(let m):
      for key in m.keys where !folder.foldStep(child, key.value) {
        break
      }
    default:
      return Value.valOrError(foldRange, "got '\(goTypeName(foldRange))', expected iterable type")
    }
    return folder.evalResult(child)
  }
}

/// The scope and state of one comprehension evaluation (cel-go `folder`): resolves the accumulator
/// (initialised lazily, so `cel.bind`-style folds keep evaluation order) and the iteration
/// variables, and delegates every other name to the enclosing frame.
final class Folder: PartialActivation {
  let fold: EvalFold
  let parentFrame: ExecutionFrame

  var accuVal: Value = .null
  var iterVar1Val: Value = .null
  var iterVar2Val: Value = .null

  var initialized = false
  var mutableValue = false
  var interrupted = false
  var computeResult = false

  init(fold: EvalFold, parentFrame: ExecutionFrame) {
    self.fold = fold
    self.parentFrame = parentFrame
  }

  /// One iteration of a one-variable comprehension; false stops the loop.
  @inline(__always)
  func foldStep(_ frame: ExecutionFrame, _ elem: Value) -> Bool {
    iterVar1Val = elem
    return iterate(frame)
  }

  /// One iteration of a two-variable comprehension; false stops the loop (cel-go `FoldEntry`).
  @inline(__always)
  func foldEntry(_ frame: ExecutionFrame, _ key: Value, _ val: Value) -> Bool {
    iterVar1Val = key
    iterVar2Val = val
    return iterate(frame)
  }

  private func iterate(_ frame: ExecutionFrame) -> Bool {
    let cond = fold.cond.eval(frame)
    if interrupted {
      return false
    }
    if !fold.exhaustive, case .bool(let b) = cond, !b {
      return false
    }
    accuVal = fold.step.eval(frame)
    initialized = true
    if fold.interruptable && frame.checkInterrupt() {
      interrupted = true
      return false
    }
    // Swift addition: the cost limit cancels the evaluation; stop at the next iteration.
    if frame.isCancelled {
      interrupted = true
      return false
    }
    return true
  }

  /// Computes the result after the loop (cel-go `evalResult`).
  func evalResult(_ frame: ExecutionFrame) -> Value {
    computeResult = true
    if interrupted {
      return .error(EvalError(interruptErrorMessage))
    }
    let res = fold.result.eval(frame)
    if mutableValue && !res.isUnknownOrError {
      if case .list(let l) = res, let mutable = l as? MutableList {
        return .list(mutable.toImmutableList())
      }
      if case .map(let m) = res, let mutable = m as? MutableMap {
        return .map(mutable.toImmutableMap())
      }
    }
    return res
  }

  func resolveName(_ name: String) -> Value? {
    if name == fold.accuVar {
      if !initialized {
        initialized = true
        var initVal = fold.accu.eval(parentFrame)
        if !fold.exhaustive {
          if case .list(let l) = initVal, l.count == 0 {
            initVal = .list(MutableList())
            mutableValue = true
          }
          if case .map(let m) = initVal, m.count == 0 {
            initVal = .map(MutableMap())
            mutableValue = true
          }
        }
        accuVal = initVal
      }
      return accuVal
    }
    if !computeResult {
      if name == fold.iterVar {
        return iterVar1Val
      }
      if !fold.iterVar2.isEmpty && name == fold.iterVar2 {
        return iterVar2Val
      }
    }
    return parentFrame.resolveName(name)
  }

  var parent: (any Activation)? { parentFrame }

  /// The enclosing frame, without this scope's variables.
  var unwrapped: (any Activation)? { parentFrame }

  func isLocalVariable(_ name: String) -> Bool {
    if name == fold.accuVar {
      return true
    }
    if !computeResult && (name == fold.iterVar || (!fold.iterVar2.isEmpty && name == fold.iterVar2)) {
      return true
    }
    return parentFrame.isLocalVariable(name)
  }

  var unknownAttributePatterns: [AttributePattern] {
    parentFrame.asPartialActivation()?.unknownAttributePatterns ?? []
  }

  /// The folder itself when the enclosing scope is partial, so local variables shadow patterns.
  func asPartialActivation() -> (any PartialActivation)? {
    parentFrame.asPartialActivation() == nil ? nil : self
  }
}

// MARK: - Attributes

/// Evaluates an attribute (cel-go `evalAttr`).
final class EvalAttr: InterpretableAttribute {
  let attr: any Attribute
  let optional: Bool

  init(attr: any Attribute, optional: Bool = false) {
    self.attr = attr
    self.optional = optional
  }

  var id: Int64 { attr.id }

  var isOptional: Bool { optional }

  func withQualifier(_ qualifier: any Qualifier) throws -> any InterpretableAttribute {
    EvalAttr(attr: try attr.addingQualifier(qualifier), optional: optional)
  }

  func eval(_ frame: ExecutionFrame) -> Value {
    do {
      return try attr.resolve(frame)
    } catch {
      return .error(error.evalError.labelled(with: id))
    }
  }

  func qualify(_ vars: ExecutionFrame, _ obj: Value) throws(ResolveError) -> Value {
    try attr.qualify(vars, obj)
  }

  func qualifyIfPresent(_ vars: ExecutionFrame, _ obj: Value, presenceOnly: Bool) throws(ResolveError)
    -> (Value?, Bool)
  {
    try attr.qualifyIfPresent(vars, obj, presenceOnly: presenceOnly)
  }

  func resolve(_ vars: ExecutionFrame) throws(ResolveError) -> Value {
    try attr.resolve(vars)
  }
}

/// A presence test `has(a.b)` (cel-go `evalTestOnly`).
final class EvalTestOnly: InterpretableAttribute {
  let testID: Int64
  let inner: any InterpretableAttribute

  init(id: Int64, inner: any InterpretableAttribute) {
    self.testID = id
    self.inner = inner
  }

  var id: Int64 { testID }
  var attr: any Attribute { inner.attr }
  var isOptional: Bool { inner.isOptional }

  /// Appends a qualifier that only tests presence; it must be a constant.
  func withQualifier(_ qualifier: any Qualifier) throws -> any InterpretableAttribute {
    guard let cq = qualifier as? any ConstantQualifier else {
      throw PlanError("test only expressions must have constant qualifiers: \(qualifier)")
    }
    return EvalTestOnly(id: testID, inner: try inner.withQualifier(TestOnlyQualifier(cq)))
  }

  func eval(_ frame: ExecutionFrame) -> Value {
    let val: Value
    do {
      val = try inner.resolve(frame)
    } catch {
      return .error(error.evalError.labelled(with: testID))
    }
    if case .optional(let opt) = val {
      return .bool(opt != nil)
    }
    return val
  }

  func qualify(_ vars: ExecutionFrame, _ obj: Value) throws(ResolveError) -> Value {
    try inner.qualify(vars, obj)
  }

  func qualifyIfPresent(_ vars: ExecutionFrame, _ obj: Value, presenceOnly: Bool) throws(ResolveError)
    -> (Value?, Bool)
  {
    try inner.qualifyIfPresent(vars, obj, presenceOnly: presenceOnly)
  }

  func resolve(_ vars: ExecutionFrame) throws(ResolveError) -> Value {
    try inner.resolve(vars)
  }
}

/// A constant qualifier that only tests presence (cel-go `testOnlyQualifier`).
final class TestOnlyQualifier: ConstantQualifier, QualifierValueEquator {
  let inner: any ConstantQualifier

  init(_ inner: any ConstantQualifier) {
    self.inner = inner
  }

  var id: Int64 { inner.id }
  var isOptional: Bool { inner.isOptional }
  var value: Value { inner.value }

  func qualify(_ vars: ExecutionFrame, _ obj: Value) throws(ResolveError) -> Value {
    let (out, present) = try inner.qualifyIfPresent(vars, obj, presenceOnly: true)
    if let out, case .unknown = out {
      return out
    }
    return .bool(present)
  }

  func qualifyIfPresent(_ vars: ExecutionFrame, _ obj: Value, presenceOnly: Bool) throws(ResolveError)
    -> (Value?, Bool)
  {
    try inner.qualifyIfPresent(vars, obj, presenceOnly: true)
  }

  func qualifierValueEquals(_ pattern: AttributeQualifier) -> Bool {
    if case .string(let s) = inner.value, case .string(let p) = pattern {
      return utf8Equal(s, p)
    }
    return false
  }
}

// MARK: - Optimized nodes

/// Hashable form of a primitive value with Go map-key semantics: `1`, `1u` and `1.0` are distinct.
enum PrimitiveKey: Hashable {
  case bool(Bool)
  case int(Int64)
  case uint(UInt64)
  case double(Double)
  case string([UInt8])

  init?(_ value: Value) {
    switch value {
    case .bool(let b): self = .bool(b)
    case .int(let i): self = .int(i)
    case .uint(let u): self = .uint(u)
    case .double(let d): self = .double(d)
    case .string(let s): self = .string(Array(s.utf8))
    default: return nil
    }
  }
}

/// `x in [constant list]` as a hash set lookup (cel-go `evalSetMembership`).
final class EvalSetMembership: Interpretable {
  let inst: any Interpretable
  let arg: any Interpretable
  let valueSet: Set<PrimitiveKey>

  init(inst: any Interpretable, arg: any Interpretable, valueSet: Set<PrimitiveKey>) {
    self.inst = inst
    self.arg = arg
    self.valueSet = valueSet
  }

  var id: Int64 { inst.id }

  func eval(_ frame: ExecutionFrame) -> Value {
    let val = arg.eval(frame)
    if val.isUnknownOrError {
      return val
    }
    if let key = PrimitiveKey(val), valueSet.contains(key) {
      return .bool(true)
    }
    return .bool(false)
  }
}

// MARK: - Exhaustive evaluation

/// `||` evaluating every term (cel-go `evalExhaustiveOr`).
final class EvalExhaustiveOr: Interpretable {
  let id: Int64
  let terms: [any Interpretable]

  init(id: Int64, terms: [any Interpretable]) {
    self.id = id
    self.terms = terms
  }

  func eval(_ frame: ExecutionFrame) -> Value {
    var err: Value?
    var unknown: UnknownSet?
    var isTrue = false
    for term in terms {
      let val = term.eval(frame)
      if case .bool(let b) = val {
        if b { isTrue = true }
        continue
      }
      if !isTrue {
        let isUnknown: Bool
        (unknown, isUnknown) = Value.maybeMergeUnknowns(val, unknown)
        if !isUnknown && err == nil {
          err = Value.maybeNoSuchOverload(val)
        }
      }
    }
    if isTrue { return .bool(true) }
    if let unknown { return .unknown(unknown) }
    if let err { return err }
    return .bool(false)
  }
}

/// `&&` evaluating every term (cel-go `evalExhaustiveAnd`).
final class EvalExhaustiveAnd: Interpretable {
  let id: Int64
  let terms: [any Interpretable]

  init(id: Int64, terms: [any Interpretable]) {
    self.id = id
    self.terms = terms
  }

  func eval(_ frame: ExecutionFrame) -> Value {
    var err: Value?
    var unknown: UnknownSet?
    var isFalse = false
    for term in terms {
      let val = term.eval(frame)
      if case .bool(let b) = val {
        if !b { isFalse = true }
        continue
      }
      if !isFalse {
        let isUnknown: Bool
        (unknown, isUnknown) = Value.maybeMergeUnknowns(val, unknown)
        if !isUnknown && err == nil {
          err = Value.maybeNoSuchOverload(val)
        }
      }
    }
    if isFalse { return .bool(false) }
    if let unknown { return .unknown(unknown) }
    if let err { return err }
    return .bool(true)
  }
}

/// `?:` evaluating both branches (cel-go `evalExhaustiveConditional`).
final class EvalExhaustiveConditional: Interpretable {
  let id: Int64
  let attr: ConditionalAttribute

  init(id: Int64, attr: ConditionalAttribute) {
    self.id = id
    self.attr = attr
  }

  func eval(_ frame: ExecutionFrame) -> Value {
    let cVal = attr.expr.eval(frame)
    let tVal: Result<Value, ResolveError>
    let fVal: Result<Value, ResolveError>
    do { tVal = .success(try attr.truthy.resolve(frame)) } catch { tVal = .failure(error) }
    do { fVal = .success(try attr.falsy.resolve(frame)) } catch { fVal = .failure(error) }
    guard case .bool(let c) = cVal else {
      return Value.valOrError(cVal, "no such overload")
    }
    switch c ? tVal : fVal {
    case .success(let v): return v
    case .failure(let err): return .error(err.evalError.labelled(with: id))
    }
  }
}

// MARK: - Observation

/// Receives the value of every evaluated node (cel-go `EvalObserver`). `step` is the interpretable
/// or qualifier that produced the value.
package typealias EvalObserver = @Sendable (_ frame: ExecutionFrame, _ id: Int64, _ step: Any, _ value: Value) -> Void

/// Observes a node's value (cel-go `evalWatch`).
final class EvalWatch: Interpretable {
  let inner: any Interpretable
  let observer: EvalObserver

  init(_ inner: any Interpretable, observer: @escaping EvalObserver) {
    self.inner = inner
    self.observer = observer
  }

  var id: Int64 { inner.id }

  func eval(_ frame: ExecutionFrame) -> Value {
    let val = inner.eval(frame)
    observer(frame, id, inner, val)
    return val
  }
}

/// Observes a constant (cel-go `evalWatchConst`).
final class EvalWatchConst: InterpretableConst {
  let inner: any InterpretableConst
  let observer: EvalObserver

  init(_ inner: any InterpretableConst, observer: @escaping EvalObserver) {
    self.inner = inner
    self.observer = observer
  }

  var id: Int64 { inner.id }
  var value: Value { inner.value }

  func eval(_ frame: ExecutionFrame) -> Value {
    let val = inner.value
    observer(frame, id, inner, val)
    return val
  }
}

/// Observes a constructor (cel-go `evalWatchConstructor`).
final class EvalWatchConstructor: InterpretableConstructor {
  let inner: any InterpretableConstructor
  let observer: EvalObserver

  init(_ inner: any InterpretableConstructor, observer: @escaping EvalObserver) {
    self.inner = inner
    self.observer = observer
  }

  var id: Int64 { inner.id }
  var initVals: [any Interpretable] { inner.initVals }
  var constructedType: CELType { inner.constructedType }

  func eval(_ frame: ExecutionFrame) -> Value {
    let val = inner.eval(frame)
    observer(frame, id, inner, val)
    return val
  }
}

/// Observes an attribute and the qualifications added to it (cel-go `evalWatchAttr`).
final class EvalWatchAttr: InterpretableAttribute {
  let inner: any InterpretableAttribute
  let observer: EvalObserver

  init(_ inner: any InterpretableAttribute, observer: @escaping EvalObserver) {
    self.inner = inner
    self.observer = observer
  }

  var id: Int64 { inner.id }
  var attr: any Attribute { inner.attr }
  var isOptional: Bool { inner.isOptional }

  /// Wraps the qualifier so its result is observed too.
  func withQualifier(_ qualifier: any Qualifier) throws -> any InterpretableAttribute {
    let wrapped: any Qualifier
    if let cq = qualifier as? any ConstantQualifier {
      wrapped = EvalWatchConstQual(cq, observer: observer)
    } else if let watch = qualifier as? EvalWatchAttr {
      // Observed during qualification rather than evaluation.
      wrapped = EvalWatchAttrQual(watch.inner, observer: observer)
    } else if let attribute = qualifier as? any Attribute {
      wrapped = EvalWatchAttrQual(attribute, observer: observer)
    } else {
      wrapped = EvalWatchQual(qualifier, observer: observer)
    }
    return EvalWatchAttr(try inner.withQualifier(wrapped), observer: observer)
  }

  func eval(_ frame: ExecutionFrame) -> Value {
    let val = inner.eval(frame)
    observer(frame, id, inner, val)
    return val
  }

  func qualify(_ vars: ExecutionFrame, _ obj: Value) throws(ResolveError) -> Value {
    try inner.qualify(vars, obj)
  }

  func qualifyIfPresent(_ vars: ExecutionFrame, _ obj: Value, presenceOnly: Bool) throws(ResolveError)
    -> (Value?, Bool)
  {
    try inner.qualifyIfPresent(vars, obj, presenceOnly: presenceOnly)
  }

  func resolve(_ vars: ExecutionFrame) throws(ResolveError) -> Value {
    try inner.resolve(vars)
  }
}

/// Observes a qualification and returns its result (shared by the qualifier watchers).
@inline(__always)
private func observeQualify(
  _ observer: EvalObserver, _ vars: ExecutionFrame, _ id: Int64, _ step: Any,
  _ body: () throws(ResolveError) -> Value
) throws(ResolveError) -> Value {
  do {
    let out = try body()
    observer(vars, id, step, out)
    return out
  } catch {
    observer(vars, id, step, .error(error.evalError.labelled(with: id)))
    throw error
  }
}

@inline(__always)
private func observeQualifyIfPresent(
  _ observer: EvalObserver, _ vars: ExecutionFrame, _ id: Int64, _ step: Any, presenceOnly: Bool,
  _ body: () throws(ResolveError) -> (Value?, Bool)
) throws(ResolveError) -> (Value?, Bool) {
  do {
    let (out, present) = try body()
    if present || presenceOnly {
      let val: Value = out ?? .bool(present)
      observer(vars, id, step, val)
    }
    return (out, present)
  } catch {
    // cel-go records a failed qualification only for presence tests: the error comes back with
    // `present == false`, and the observer is called when `present || presenceOnly`.
    if presenceOnly {
      observer(vars, id, step, .error(error.evalError.labelled(with: id)))
    }
    throw error
  }
}

/// Observes a constant qualification (cel-go `evalWatchConstQual`).
final class EvalWatchConstQual: ConstantQualifier, QualifierValueEquator {
  let inner: any ConstantQualifier
  let observer: EvalObserver

  init(_ inner: any ConstantQualifier, observer: @escaping EvalObserver) {
    self.inner = inner
    self.observer = observer
  }

  var id: Int64 { inner.id }
  var isOptional: Bool { inner.isOptional }
  var value: Value { inner.value }

  func qualify(_ vars: ExecutionFrame, _ obj: Value) throws(ResolveError) -> Value {
    try observeQualify(observer, vars, id, inner) { () throws(ResolveError) -> Value in
      try inner.qualify(vars, obj)
    }
  }

  func qualifyIfPresent(_ vars: ExecutionFrame, _ obj: Value, presenceOnly: Bool) throws(ResolveError)
    -> (Value?, Bool)
  {
    try observeQualifyIfPresent(observer, vars, id, inner, presenceOnly: presenceOnly) {
      () throws(ResolveError) -> (Value?, Bool) in
      try inner.qualifyIfPresent(vars, obj, presenceOnly: presenceOnly)
    }
  }

  func qualifierValueEquals(_ pattern: AttributeQualifier) -> Bool {
    (inner as? any QualifierValueEquator)?.qualifierValueEquals(pattern) ?? false
  }
}

/// Observes a qualification by an attribute (cel-go `evalWatchAttrQual`).
final class EvalWatchAttrQual: Attribute {
  let inner: any Attribute
  let observer: EvalObserver

  init(_ inner: any Attribute, observer: @escaping EvalObserver) {
    self.inner = inner
    self.observer = observer
  }

  var id: Int64 { inner.id }
  var isOptional: Bool { inner.isOptional }

  func addingQualifier(_ qualifier: any Qualifier) throws -> any Attribute {
    EvalWatchAttrQual(try inner.addingQualifier(qualifier), observer: observer)
  }

  func resolve(_ vars: ExecutionFrame) throws(ResolveError) -> Value {
    try inner.resolve(vars)
  }

  func qualify(_ vars: ExecutionFrame, _ obj: Value) throws(ResolveError) -> Value {
    try observeQualify(observer, vars, id, inner) { () throws(ResolveError) -> Value in
      try inner.qualify(vars, obj)
    }
  }

  func qualifyIfPresent(_ vars: ExecutionFrame, _ obj: Value, presenceOnly: Bool) throws(ResolveError)
    -> (Value?, Bool)
  {
    try observeQualifyIfPresent(observer, vars, id, inner, presenceOnly: presenceOnly) {
      () throws(ResolveError) -> (Value?, Bool) in
      try inner.qualifyIfPresent(vars, obj, presenceOnly: presenceOnly)
    }
  }
}

/// Observes a custom qualifier (cel-go `evalWatchQual`).
final class EvalWatchQual: Qualifier {
  let inner: any Qualifier
  let observer: EvalObserver

  init(_ inner: any Qualifier, observer: @escaping EvalObserver) {
    self.inner = inner
    self.observer = observer
  }

  var id: Int64 { inner.id }
  var isOptional: Bool { inner.isOptional }

  func qualify(_ vars: ExecutionFrame, _ obj: Value) throws(ResolveError) -> Value {
    try observeQualify(observer, vars, id, inner) { () throws(ResolveError) -> Value in
      try inner.qualify(vars, obj)
    }
  }

  func qualifyIfPresent(_ vars: ExecutionFrame, _ obj: Value, presenceOnly: Bool) throws(ResolveError)
    -> (Value?, Bool)
  {
    try observeQualifyIfPresent(observer, vars, id, inner, presenceOnly: presenceOnly) {
      () throws(ResolveError) -> (Value?, Bool) in
      try inner.qualifyIfPresent(vars, obj, presenceOnly: presenceOnly)
    }
  }
}

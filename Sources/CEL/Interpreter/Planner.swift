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
// Ported from cel-go interpreter/planner.go.

/// Decorates or replaces interpretables as they are planned (cel-go `InterpretableDecoratorV2`).
package typealias InterpretableDecorator = (any Interpretable) throws -> any Interpretable

extension Constant {
  /// The literal as a runtime value.
  package var value: Value {
    switch self {
    case .null: return .null
    case .bool(let b): return .bool(b)
    case .int(let i): return .int(i)
    case .uint(let u): return .uint(u)
    case .double(let d): return .double(d)
    case .string(let s): return .string(s)
    case .bytes(let b): return .bytes(b)
    }
  }
}

/// Turns a checked or parse-only AST into a tree of interpretables, resolving functions, types and
/// namespaced identifiers once at plan time (cel-go `planner`).
package final class Planner {
  package let dispatcher: Dispatcher
  package let provider: any TypeProvider
  package let attrFactory: any AttributeFactory
  package let container: Container
  package let refMap: [Int64: ReferenceInfo]
  package let typeMap: [Int64: CELType]
  package var decorators: [InterpretableDecorator] = []
  package var observers: [any StatefulObserver] = []

  package init(
    dispatcher: Dispatcher, provider: any TypeProvider, attrFactory: any AttributeFactory,
    container: Container, ast: AST
  ) {
    self.dispatcher = dispatcher
    self.provider = provider
    self.attrFactory = attrFactory
    self.container = container
    self.refMap = ast.referenceMap
    self.typeMap = ast.typeMap
  }

  /// Plans an expression, applying the decorators to every node and wrapping the root for the
  /// observers (cel-go `Plan`).
  package func plan(_ expr: Expr) throws -> any Interpretable {
    var decorators = self.decorators
    if !observers.isEmpty {
      // One decorator reports to every observer.
      decorators.append(decObserveEval(observeAll(observers)))
    }
    let builder = PlanBuilder(planner: self, decorators: decorators)
    let root = try builder.plan(expr)
    if observers.isEmpty {
      return root
    }
    return ObservableInterpretable(root, observers: observers)
  }
}

private func observeAll(_ observers: [any StatefulObserver]) -> EvalObserver {
  if observers.count == 1 {
    let observer = observers[0]
    return { frame, id, step, value in observer.observe(frame, id, step, value) }
  }
  return { frame, id, step, value in
    for o in observers {
      o.observe(frame, id, step, value)
    }
  }
}

/// The recursive planning walk with its local-variable scope (cel-go `planBuilder`).
final class PlanBuilder {
  let p: Planner
  let decorators: [InterpretableDecorator]
  var localVars: [String: Int] = [:]

  init(planner: Planner, decorators: [InterpretableDecorator]) {
    self.p = planner
    self.decorators = decorators
  }

  func plan(_ expr: Expr) throws -> any Interpretable {
    switch expr.kind {
    case .call(let call): return try decorate(planCall(expr, call))
    case .ident(let name): return try decorate(planIdent(expr.id, name))
    case .literal(let c): return try decorate(EvalConst(id: expr.id, value: c.value))
    case .select(let sel): return try decorate(planSelect(expr.id, sel))
    case .list(let list): return try decorate(planCreateList(expr.id, list))
    case .map(let map): return try decorate(planCreateMap(expr.id, map))
    case .struct(let s): return try decorate(planCreateStruct(expr.id, s))
    case .comprehension(let c): return try decorate(planComprehension(expr.id, c))
    case .unspecified: throw PlanError("unsupported expr: \(expr.id)")
    }
  }

  /// Applies every decorator (cel-go `decorate`).
  func decorate(_ i: any Interpretable) throws -> any Interpretable {
    var out = i
    for dec in decorators {
      out = try dec(out)
    }
    return out
  }

  // MARK: Identifiers and selection

  func planIdent(_ id: Int64, _ name: String) throws -> any Interpretable {
    if let ref = p.refMap[id] {
      return try planCheckedIdent(id, ref)
    }
    if isLocalVar(name) {
      return EvalAttr(attr: p.attrFactory.absoluteAttribute(id: id, names: [name]))
    }
    return EvalAttr(attr: p.attrFactory.maybeAttribute(id: id, name: name))
  }

  func planCheckedIdent(_ id: Int64, _ ref: ReferenceInfo) throws -> any Interpretable {
    if let value = ref.value {
      return EvalConst(id: id, value: value)
    }
    // A type name resolves to the type value registered with the provider.
    if let type = p.typeMap[id], type.kind == .type {
      guard let value = p.provider.findIdent(ref.name) else {
        throw PlanError("reference to undefined type: \(ref.name)")
      }
      return EvalConst(id: id, value: value)
    }
    return EvalAttr(attr: p.attrFactory.absoluteAttribute(id: id, names: [ref.name]))
  }

  /// A field selection, a presence test, or a namespaced identifier (cel-go `planSelect`).
  func planSelect(_ id: Int64, _ sel: Expr.Select) throws -> any Interpretable {
    if let ref = p.refMap[id] {
      return try planCheckedIdent(id, ref)
    }
    let op = try plan(sel.operand)
    let opType = p.typeMap[sel.operand.id]
    var attr: any InterpretableAttribute
    if let a = op as? any InterpretableAttribute {
      attr = a
    } else {
      attr = try relativeAttr(op.id, op, optional: false)
    }
    let qual: any Qualifier
    do {
      qual = try p.attrFactory.newQualifier(
        objType: opType, qualID: id, value: .value(.string(sel.field)), optional: false)
    } catch {
      throw PlanError(error.evalError.message)
    }
    if sel.testOnly {
      attr = EvalTestOnly(id: id, inner: attr)
    }
    return try attr.withQualifier(qual)
  }

  // MARK: Calls

  func planCall(_ expr: Expr, _ call: Expr.Call) throws -> any Interpretable {
    let (target, fnName, oName) = resolveFunction(expr.id, call)
    var args: [any Interpretable] = []
    args.reserveCapacity(call.args.count + 1)
    if let target {
      args.append(try plan(target))
    }
    for arg in call.args {
      args.append(try plan(arg))
    }

    switch fnName {
    case Operators.logicalAnd: return EvalAnd(id: expr.id, terms: args)
    case Operators.logicalOr: return EvalOr(id: expr.id, terms: args)
    case Operators.conditional: return try planCallConditional(expr.id, args)
    case Operators.equals: return EvalEq(id: expr.id, lhs: args[0], rhs: args[1])
    case Operators.notEquals: return EvalNe(id: expr.id, lhs: args[0], rhs: args[1])
    case Operators.index: return try planCallIndex(expr.id, args, optional: false)
    case Operators.optSelect, Operators.optIndex: return try planCallIndex(expr.id, args, optional: true)
    default: break
    }

    var fnDef: FunctionBinding?
    if !oName.isEmpty {
      fnDef = p.dispatcher.findOverload(oName)
    }
    if fnDef == nil {
      fnDef = p.dispatcher.findOverload(fnName)
    }
    switch args.count {
    case 0:
      guard let fn = fnDef?.function else {
        throw PlanError("no such overload: \(fnName)()")
      }
      return EvalZeroArity(id: expr.id, function: fnName, overloadID: oName, impl: fn)
    case 1:
      if let fnDef, fnDef.unary == nil, fnDef.function != nil {
        return try planCallVarArgs(expr.id, fnName, oName, fnDef, args)
      }
      if let fnDef, fnDef.unary == nil {
        throw PlanError("no such overload: \(fnName)(arg)")
      }
      return EvalUnary(
        id: expr.id, function: fnName, overloadID: oName, arg: args[0], trait: fnDef?.operandTraits ?? [],
        impl: fnDef?.unary, nonStrict: fnDef?.isNonStrict ?? false)
    case 2:
      if let fnDef, fnDef.binary == nil, fnDef.function != nil {
        return try planCallVarArgs(expr.id, fnName, oName, fnDef, args)
      }
      if let fnDef, fnDef.binary == nil {
        throw PlanError("no such overload: \(fnName)(lhs, rhs)")
      }
      return EvalBinary(
        id: expr.id, function: fnName, overloadID: oName, lhs: args[0], rhs: args[1],
        trait: fnDef?.operandTraits ?? [], impl: fnDef?.binary, nonStrict: fnDef?.isNonStrict ?? false)
    default:
      return try planCallVarArgs(expr.id, fnName, oName, fnDef, args)
    }
  }

  func planCallVarArgs(
    _ id: Int64, _ function: String, _ overload: String, _ impl: FunctionBinding?,
    _ args: [any Interpretable]
  ) throws -> any Interpretable {
    if let impl, impl.function == nil {
      throw PlanError("no such overload: \(function)(...)")
    }
    return EvalVarArgs(
      id: id, function: function, overloadID: overload, args: args, trait: impl?.operandTraits ?? [],
      impl: impl?.function, nonStrict: impl?.isNonStrict ?? false)
  }

  /// `c ? t : f` as a conditional attribute, so qualifiers on the result apply to both branches.
  func planCallConditional(_ id: Int64, _ args: [any Interpretable]) throws -> any Interpretable {
    let cond = args[0]
    let t = args[1]
    let tAttr: any Attribute =
      (t as? any InterpretableAttribute)?.attr ?? p.attrFactory.relativeAttribute(id: t.id, operand: t)
    let f = args[2]
    let fAttr: any Attribute =
      (f as? any InterpretableAttribute)?.attr ?? p.attrFactory.relativeAttribute(id: f.id, operand: f)
    return EvalAttr(attr: p.attrFactory.conditionalAttribute(id: id, expr: cond, truthy: tAttr, falsy: fAttr))
  }

  /// Extends an attribute with an index or optional select/index qualifier, or qualifies the result
  /// of a computation (cel-go `planCallIndex`).
  func planCallIndex(_ id: Int64, _ args: [any Interpretable], optional: Bool) throws -> any Interpretable {
    let op = args[0]
    let ind = args[1]
    let opType = p.typeMap[op.id]
    var attr: any InterpretableAttribute
    if let a = op as? any InterpretableAttribute {
      attr = a
    } else {
      attr = try relativeAttr(op.id, op, optional: false)
    }
    let qual: any Qualifier
    do {
      if let c = ind as? any InterpretableConst {
        qual = try p.attrFactory.newQualifier(objType: opType, qualID: id, value: .value(c.value), optional: optional)
      } else if let a = ind as? any InterpretableAttribute {
        qual = try p.attrFactory.newQualifier(objType: opType, qualID: id, value: .attribute(a), optional: optional)
      } else {
        qual = try relativeAttr(id, ind, optional: optional)
      }
    } catch let error as ResolveError {
      throw PlanError(error.evalError.message)
    }
    attr = try attr.withQualifier(qual)
    return attr
  }

  // MARK: Constructors

  func planCreateList(_ id: Int64, _ list: Expr.List) throws -> any Interpretable {
    var optionals = [Bool](repeating: false, count: list.elements.count)
    for index in list.optionalIndices {
      if index < 0 || Int(index) >= list.elements.count {
        throw PlanError("optional index \(index) out of element bounds [0, \(list.elements.count)]")
      }
      optionals[Int(index)] = true
    }
    var elems: [any Interpretable] = []
    elems.reserveCapacity(list.elements.count)
    for elem in list.elements {
      elems.append(try plan(elem))
    }
    return EvalList(id: id, elems: elems, optionals: optionals, hasOptionals: !list.optionalIndices.isEmpty)
  }

  func planCreateMap(_ id: Int64, _ map: Expr.Map) throws -> any Interpretable {
    var keys: [any Interpretable] = []
    var vals: [any Interpretable] = []
    var optionals: [Bool] = []
    var hasOptionals = false
    for entry in map.entries {
      keys.append(try plan(entry.key))
      vals.append(try plan(entry.value))
      optionals.append(entry.isOptional)
      hasOptionals = hasOptionals || entry.isOptional
    }
    return EvalMap(id: id, keys: keys, vals: vals, optionals: optionals, hasOptionals: hasOptionals)
  }

  func planCreateStruct(_ id: Int64, _ obj: Expr.Struct) throws -> any Interpretable {
    guard let typeName = resolveTypeName(obj.typeName) else {
      throw PlanError("unknown type: \(obj.typeName)")
    }
    var fields: [String] = []
    var vals: [any Interpretable] = []
    var optionals: [Bool] = []
    var hasOptionals = false
    for field in obj.fields {
      fields.append(field.name)
      vals.append(try plan(field.value))
      optionals.append(field.isOptional)
      hasOptionals = hasOptionals || field.isOptional
    }
    return EvalObj(
      id: id, typeName: typeName, fields: fields, vals: vals, optionals: optionals,
      hasOptionals: hasOptionals, provider: p.provider)
  }

  func planComprehension(_ id: Int64, _ fold: Expr.Comprehension) throws -> any Interpretable {
    let accu = try plan(fold.accuInit)
    let iterRange = try plan(fold.iterRange)
    pushLocalVars(fold.accuVar, fold.iterVar, fold.iterVar2)
    let cond = try plan(fold.loopCondition)
    let step = try plan(fold.loopStep)
    popLocalVars(fold.iterVar, fold.iterVar2)
    let result = try plan(fold.result)
    popLocalVars(fold.accuVar)
    return EvalFold(
      id: id, accuVar: fold.accuVar, iterVar: fold.iterVar, iterVar2: fold.iterVar2, iterRange: iterRange,
      accu: accu, cond: cond, step: step, result: result)
  }

  // MARK: Name resolution

  /// The first candidate of a type name in the container known to the provider.
  func resolveTypeName(_ typeName: String) -> String? {
    for qualified in p.container.resolveCandidateNames(typeName)
    where p.provider.findStructType(qualified) != nil {
      return qualified
    }
    return nil
  }

  /// The call target, function name and overload id. A receiver-style call whose target is a
  /// (qualified) name may really be a call of a namespaced global function (cel-go
  /// `resolveFunction`).
  func resolveFunction(_ id: Int64, _ call: Expr.Call) -> (Expr?, String, String) {
    let target = call.target
    let fnName = call.function
    if let ref = p.refMap[id] {
      if ref.overloadIDs.count == 1 {
        return (target, fnName, ref.overloadIDs[0])
      }
      return (target, fnName, "")
    }
    guard let target else {
      for qualified in p.container.resolveCandidateNames(fnName)
      where p.dispatcher.findOverload(qualified) != nil {
        return (nil, qualified, "")
      }
      if fnName.utf8.first == UInt8(ascii: ".") {
        return (nil, String(decoding: fnName.utf8.dropFirst(), as: UTF8.self), "")
      }
      return (nil, fnName, "")
    }
    if let prefix = toQualifiedName(target) {
      for qualified in p.container.resolveCandidateNames(prefix + "." + fnName)
      where p.dispatcher.findOverload(qualified) != nil {
        return (nil, qualified, "")
      }
    }
    return (target, fnName, "")
  }

  /// The dotted name an ident / select chain spells, unless the checker resolved it as a variable.
  func toQualifiedName(_ operand: Expr) -> String? {
    if p.refMap[operand.id] != nil {
      return nil
    }
    switch operand.kind {
    case .ident(let name):
      return name
    case .select(let sel):
      if sel.testOnly {
        return nil
      }
      if let qual = toQualifiedName(sel.operand) {
        return qual + "." + sel.field
      }
      return nil
    default:
      return nil
    }
  }

  /// A relative attribute over a computed value, decorated so its value is observed (cel-go
  /// `relativeAttr`).
  func relativeAttr(_ id: Int64, _ eval: any Interpretable, optional: Bool) throws
    -> any InterpretableAttribute
  {
    let eAttr: any Interpretable =
      eval as? any InterpretableAttribute
      ?? EvalAttr(attr: p.attrFactory.relativeAttribute(id: id, operand: eval), optional: optional)
    let decorated = try decorate(eAttr)
    guard let attr = decorated as? any InterpretableAttribute else {
      throw PlanError("invalid attribute decoration: \(type(of: decorated))")
    }
    return attr
  }

  private func pushLocalVars(_ names: String...) {
    for name in names where !name.isEmpty {
      localVars[name, default: 0] += 1
    }
  }

  private func popLocalVars(_ names: String...) {
    for name in names where !name.isEmpty {
      if let count = localVars[name] {
        localVars[name] = count == 1 ? nil : count - 1
      }
    }
  }

  private func isLocalVar(_ name: String) -> Bool {
    localVars[name] != nil
  }
}

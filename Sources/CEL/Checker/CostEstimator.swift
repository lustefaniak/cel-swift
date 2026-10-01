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
// Ported from cel-go checker/cost.go. Any change to the cost formulas needs the same change in
// the runtime cost tracker (Interpreter/RuntimeCost.swift, cel-go interpreter/runtimecost.go).

// MARK: - Estimates

/// An estimated size range of a variable length string, bytes, map or list (cel-go `SizeEstimate`).
package struct SizeEstimate: Hashable, Sendable, CustomStringConvertible {
  package var min: UInt64
  package var max: UInt64

  package init(min: UInt64, max: UInt64) {
    self.min = min
    self.max = max
  }

  /// A size between 0 and `UInt64.max` (cel-go `UnknownSizeEstimate`).
  package static let unknown = SizeEstimate(min: 0, max: .max)

  /// A size with a fixed min and max (cel-go `FixedSizeEstimate`).
  package static func fixed(_ size: UInt64) -> SizeEstimate {
    SizeEstimate(min: size, max: size)
  }

  /// The saturating sum.
  package func adding(_ other: SizeEstimate) -> SizeEstimate {
    SizeEstimate(min: Cost.safeAdd(min, other.min), max: Cost.safeAdd(max, other.max))
  }

  /// The saturating product.
  package func multiplied(by other: SizeEstimate) -> SizeEstimate {
    SizeEstimate(min: Cost.safeMultiply(min, other.min), max: Cost.safeMultiply(max, other.max))
  }

  /// The cost of `costPerUnit` per unit of size, rounded up (cel-go `MultiplyByCostFactor`).
  package func multipliedByCostFactor(_ costPerUnit: Double) -> CostEstimate {
    CostEstimate(
      min: Cost.safeMultiplyByFactor(min, costPerUnit), max: Cost.safeMultiplyByFactor(max, costPerUnit))
  }

  /// The cost of `cost` per unit of size (cel-go `MultiplyByCost`).
  package func multiplied(byCost cost: CostEstimate) -> CostEstimate {
    CostEstimate(min: Cost.safeMultiply(min, cost.min), max: Cost.safeMultiply(max, cost.max))
  }

  /// The smallest range covering both.
  package func union(_ other: SizeEstimate) -> SizeEstimate {
    SizeEstimate(min: Swift.min(min, other.min), max: Swift.max(max, other.max))
  }

  /// The equivalent cost estimate.
  package var asCost: CostEstimate {
    multipliedByCostFactor(1)
  }

  package var description: String { "[\(min), \(max)]" }
}

/// An estimated cost range with saturating arithmetic (cel-go `CostEstimate`).
package struct CostEstimate: Hashable, Sendable, CustomStringConvertible {
  package var min: UInt64
  package var max: UInt64

  package init(min: UInt64, max: UInt64) {
    self.min = min
    self.max = max
  }

  /// Zero.
  package static let zero = CostEstimate(min: 0, max: 0)

  /// A cost with an unknown impact (cel-go `UnknownCostEstimate`).
  package static let unknown = SizeEstimate.unknown.asCost

  /// A cost with a fixed min and max (cel-go `FixedCostEstimate`).
  package static func fixed(_ cost: UInt64) -> CostEstimate {
    CostEstimate(min: cost, max: cost)
  }

  /// The saturating sum.
  package func adding(_ other: CostEstimate) -> CostEstimate {
    CostEstimate(min: Cost.safeAdd(min, other.min), max: Cost.safeAdd(max, other.max))
  }

  /// The saturating product.
  package func multiplied(by other: CostEstimate) -> CostEstimate {
    CostEstimate(min: Cost.safeMultiply(min, other.min), max: Cost.safeMultiply(max, other.max))
  }

  /// Multiplied by a factor, rounded up.
  package func multipliedByCostFactor(_ costPerUnit: Double) -> CostEstimate {
    CostEstimate(
      min: Cost.safeMultiplyByFactor(min, costPerUnit), max: Cost.safeMultiplyByFactor(max, costPerUnit))
  }

  /// The smallest range covering both.
  package func union(_ other: CostEstimate) -> CostEstimate {
    CostEstimate(min: Swift.min(min, other.min), max: Swift.max(max, other.max))
  }

  package var description: String { "[\(min), \(max)]" }
}

/// The estimated cost of a call, with an optional estimate of the size of its result
/// (cel-go `CallEstimate`). Give a result size only for calls returning a map, list, string or bytes.
package struct CallEstimate: Hashable, Sendable {
  package var cost: CostEstimate
  package var resultSize: SizeEstimate?

  package init(cost: CostEstimate, resultSize: SizeEstimate? = nil) {
    self.cost = cost
    self.resultSize = resultSize
  }
}

/// An expression as the cost estimator describes it to a ``CostEstimator`` (cel-go `AstNode`).
package struct CostAstNode: Sendable {
  /// A field path through the declarations to the node: a variable name, then field names and
  /// `@items`, `@indices`, `@keys`, `@values`. Empty when the node is not reachable from a variable.
  package var path: [String]
  /// The deduced type.
  package var type: CELType
  /// The expression; `nil` for synthesized nodes such as list elements.
  package var expr: Expr?
  /// The size derived from the expression itself: exact for constants and literals, derived from
  /// the operands for concatenations; `nil` when unknown.
  package var computedSize: SizeEstimate?

  package init(path: [String], type: CELType, expr: Expr?, computedSize: SizeEstimate? = nil) {
    self.path = path
    self.type = type
    self.expr = expr
    self.computedSize = computedSize
  }
}

/// Estimates the sizes of variable length inputs and the costs of functions (cel-go `CostEstimator`).
package protocol CostEstimator: Sendable {
  /// The size of a node CEL cannot size by itself, or `nil` for no estimate. The size is that of
  /// CEL's `size()`: code points of a string, bytes, list elements or map entries.
  func estimateSize(_ element: CostAstNode) -> SizeEstimate?

  /// The cost of a call, or `nil` to use CEL's estimate.
  func estimateCallCost(function: String, overloadID: String, target: CostAstNode?, args: [CostAstNode])
    -> CallEstimate?
}

/// An estimator with no estimates: sizes come from the expression and types alone.
package struct DefaultCostEstimator: CostEstimator {
  package init() {}

  package func estimateSize(_ element: CostAstNode) -> SizeEstimate? { nil }

  package func estimateCallCost(
    function: String, overloadID: String, target: CostAstNode?, args: [CostAstNode]
  ) -> CallEstimate? { nil }
}

/// Estimates one overload's call cost, overriding the ``CostEstimator`` (cel-go `FunctionEstimator`).
package typealias FunctionEstimator =
  @Sendable (_ estimator: any CostEstimator, _ target: CostAstNode?, _ args: [CostAstNode]) -> CallEstimate?

/// Options of the static cost estimator (cel-go `CostOption`s).
package struct CostEstimateOptions: Sendable {
  /// Whether a presence test costs one (the default) or zero (cel-go `PresenceTestHasCost`).
  package var presenceTestHasCost = true
  /// Per-overload estimators (cel-go `OverloadCostEstimate`).
  package var overloadEstimators: [String: FunctionEstimator] = [:]

  package init(presenceTestHasCost: Bool = true, overloadEstimators: [String: FunctionEstimator] = [:]) {
    self.presenceTestHasCost = presenceTestHasCost
    self.overloadEstimators = overloadEstimators
  }

  /// Merges options contributed by libraries: later estimators win.
  package mutating func merge(_ other: CostEstimateOptions) {
    overloadEstimators.merge(other.overloadEstimators) { _, new in new }
  }
}

extension Checker {
  /// Estimates the cost of a checked expression (cel-go `checker.Cost`).
  package static func estimateCost(
    _ checked: AST, estimator: any CostEstimator = DefaultCostEstimator(),
    options: CostEstimateOptions = CostEstimateOptions()
  ) -> CostEstimate {
    var coster = Coster(checked: checked, estimator: estimator, options: options)
    var result = CostEstimate.zero
    withStack(depth: checked.expr.depth) {
      result = coster.cost(checked.expr)
    }
    return result
  }
}

// MARK: - Coster

/// The container kind and the key / index and value sizes of a list or map (cel-go
/// `entrySizeEstimate`).
struct EntrySizeEstimate {
  var containerKind: CELType.Kind
  var key: SizeEstimate
  var val: SizeEstimate

  func union(_ other: EntrySizeEstimate?) -> EntrySizeEstimate? {
    guard let other else {
      return nil
    }
    return EntrySizeEstimate(containerKind: containerKind, key: key.union(other.key), val: val.union(other.val))
  }
}

extension Optional where Wrapped == EntrySizeEstimate {
  fileprivate var container: CELType.Kind { self?.containerKind ?? .unknown }
  fileprivate var keySize: SizeEstimate? { self?.key }
  fileprivate var valSize: SizeEstimate? { self?.val }
  fileprivate func union(_ other: EntrySizeEstimate?) -> EntrySizeEstimate? {
    self?.union(other)
  }
}

/// A local or iteration variable's path and size estimates (cel-go `localVar`).
private struct LocalVar {
  var exprID: Int64
  var path: [String]
  var size: SizeEstimate?
  var entrySize: EntrySizeEstimate?
}

private let selectAndIdentCost = CostEstimate.fixed(Cost.selectAndIdentCost)
private let constCost = CostEstimate.fixed(Cost.constCost)
private let createListBaseCost = CostEstimate.fixed(Cost.listCreateBaseCost)
private let createMapBaseCost = CostEstimate.fixed(Cost.mapCreateBaseCost)
private let createMessageBaseCost = CostEstimate.fixed(Cost.structCreateBaseCost)

/// The state of one estimation (cel-go `coster`).
struct Coster {
  let checked: AST
  let estimator: any CostEstimator
  let overloadEstimators: [String: FunctionEstimator]
  let presenceTestCost: CostEstimate

  /// Field paths by expression id.
  private var exprPaths: [Int64: [String]] = [:]
  /// Local and iteration variables in scope, innermost last.
  private var localVars: [String: [LocalVar]] = [:]
  /// Computed sizes of call results.
  private var computedSizes: [Int64: SizeEstimate] = [:]
  /// Sizes of list and map entries.
  private var computedEntrySizes: [Int64: EntrySizeEstimate] = [:]

  init(checked: AST, estimator: any CostEstimator, options: CostEstimateOptions) {
    self.checked = checked
    self.estimator = estimator
    self.overloadEstimators = options.overloadEstimators
    self.presenceTestCost = options.presenceTestHasCost ? selectAndIdentCost : .zero
  }

  // MARK: Scopes

  private mutating func pushVar(_ name: String, _ expr: Expr, _ path: [String], _ size: SizeEstimate?,
    _ entrySize: EntrySizeEstimate?)
  {
    localVars[name, default: []].append(LocalVar(exprID: expr.id, path: path, size: size, entrySize: entrySize))
  }

  private mutating func popLocalVar(_ name: String) {
    _ = localVars[name]?.popLast()
  }

  private func peekLocalVar(_ name: String) -> LocalVar? {
    localVars[name]?.last
  }

  private mutating func pushIterKey(_ name: String, _ rangeExpr: Expr) {
    let entrySize = computeEntrySize(rangeExpr)
    var container = entrySize.container
    if container == .unknown {
      container = type(of: rangeExpr).kind
    }
    let subpath = container == .list ? "@indices" : "@keys"
    pushVar(name, rangeExpr, path(of: rangeExpr) + [subpath], entrySize.keySize, nil)
  }

  private mutating func pushIterValue(_ name: String, _ rangeExpr: Expr) {
    let entrySize = computeEntrySize(rangeExpr)
    var container = entrySize.container
    if container == .unknown {
      container = type(of: rangeExpr).kind
    }
    let subpath = container == .list ? "@items" : "@values"
    pushVar(name, rangeExpr, path(of: rangeExpr) + [subpath], entrySize.valSize, nil)
  }

  private mutating func pushIterSingle(_ name: String, _ rangeExpr: Expr) {
    let entrySize = computeEntrySize(rangeExpr)
    var size = entrySize.keySize
    var subpath = "@keys"
    var container = entrySize.container
    if container == .unknown {
      container = type(of: rangeExpr).kind
    }
    if container == .list {
      size = entrySize.valSize
      subpath = "@items"
    }
    pushVar(name, rangeExpr, path(of: rangeExpr) + [subpath], size, nil)
  }

  private mutating func pushLocalVar(_ name: String, _ e: Expr) {
    // The binding may be a list or map, so its entry size is propagated too.
    let p = path(of: e)
    let entrySize = computeEntrySize(e)
    let size = computeSize(e)
    pushVar(name, e, p, size, entrySize)
  }

  // MARK: Costs

  mutating func cost(_ e: Expr) -> CostEstimate {
    switch e.kind {
    case .literal:
      return constCost
    case .ident(let name):
      return costIdent(e, name)
    case .select(let sel):
      return costSelect(e, sel)
    case .call(let call):
      return costCall(e, call)
    case .list(let list):
      return costCreateList(e, list)
    case .map(let map):
      return costCreateMap(e, map)
    case .struct(let s):
      return costCreateStruct(s)
    case .comprehension(let comp):
      return isBind(comp) ? costBind(e, comp) : costComprehension(e, comp)
    case .unspecified:
      return .zero
    }
  }

  private mutating func costIdent(_ e: Expr, _ name: String) -> CostEstimate {
    if let v = peekLocalVar(name) {
      addPath(e, v.path)
    } else {
      addPath(e, [name])
    }
    return selectAndIdentCost
  }

  private mutating func costSelect(_ e: Expr, _ sel: Expr.Select) -> CostEstimate {
    var sum = CostEstimate.zero
    if sel.testOnly {
      // Recurse without a cost for the qualifier, as the runtime's evalTestOnly does (the
      // operand's identifier carries the cost instead).
      sum = sum.adding(presenceTestCost)
      sum = sum.adding(cost(sel.operand))
      return sum
    }
    sum = sum.adding(cost(sel.operand))
    switch type(of: sel.operand).kind {
    case .map, .struct, .typeParam:
      sum = sum.adding(selectAndIdentCost)
    default:
      break
    }
    addPath(e, path(of: sel.operand) + [sel.field])
    return sum
  }

  private mutating func costCall(_ e: Expr, _ call: Expr.Call) -> CostEstimate {
    // dyn() only disables type checking: one plus the cost of the argument.
    if call.function == "dyn", let arg = call.args.first {
      let argCost = cost(arg)
      copySizeEstimates(e, arg)
      return CostEstimate.fixed(1).adding(argCost)
    }

    var sum = CostEstimate.zero
    var argCosts: [CostEstimate] = []
    var argNodes: [CostAstNode] = []
    argCosts.reserveCapacity(call.args.count)
    argNodes.reserveCapacity(call.args.count)
    for arg in call.args {
      argCosts.append(cost(arg))
      argNodes.append(newAstNode(arg))
    }

    guard let overloadIDs = checked.referenceMap[e.id]?.overloadIDs, !overloadIDs.isEmpty else {
      return .zero
    }
    var targetNode: CostAstNode?
    if let target = call.target {
      sum = sum.adding(cost(target))
      targetNode = newAstNode(target)
    }
    // A range covering every overload's estimate.
    var fnCost = CostEstimate(min: .max, max: 0)
    var resultSize: SizeEstimate?
    for overload in overloadIDs {
      let overloadCost = functionCost(
        e, function: call.function, overloadID: overload, target: targetNode, args: argNodes, argCosts: argCosts)
      fnCost = fnCost.union(overloadCost.cost)
      if let size = overloadCost.resultSize {
        resultSize = resultSize.map { $0.union(size) } ?? size
      }
      // Field paths for index operations.
      switch overload {
      case Overloads.indexList:
        if let first = call.args.first {
          // Possibly redundant with the path-based lookup below, as in cel-go.
          resultSize = computeEntrySize(first).valSize
          addPath(e, path(of: first) + ["@items"])
        }
      case Overloads.indexMap:
        if let first = call.args.first {
          resultSize = computeEntrySize(first).valSize
          addPath(e, path(of: first) + ["@values"])
        }
      default:
        break
      }
      if resultSize == nil {
        resultSize = computeSize(e)
      }
    }
    setSize(e, resultSize)
    return sum.adding(fnCost)
  }

  private mutating func costCreateList(_ e: Expr, _ list: Expr.List) -> CostEstimate {
    var sum = CostEstimate.zero
    var itemSize = SizeEstimate(min: .max, max: 0)
    if list.elements.isEmpty {
      itemSize.min = 0
    }
    for elem in list.elements {
      sum = sum.adding(cost(elem))
      itemSize = itemSize.union(sizeOrUnknown(elem))
    }
    setEntrySize(e, EntrySizeEstimate(containerKind: .list, key: .fixed(1), val: itemSize))
    return sum.adding(createListBaseCost)
  }

  private mutating func costCreateMap(_ e: Expr, _ map: Expr.Map) -> CostEstimate {
    var sum = CostEstimate.zero
    var keySize = SizeEstimate(min: .max, max: 0)
    var valSize = SizeEstimate(min: .max, max: 0)
    if map.entries.isEmpty {
      keySize.min = 0
      valSize.min = 0
    }
    for entry in map.entries {
      sum = sum.adding(cost(entry.key))
      sum = sum.adding(cost(entry.value))
      keySize = keySize.union(sizeOrUnknown(entry.key))
      valSize = valSize.union(sizeOrUnknown(entry.value))
    }
    setEntrySize(e, EntrySizeEstimate(containerKind: .map, key: keySize, val: valSize))
    return sum.adding(createMapBaseCost)
  }

  private mutating func costCreateStruct(_ s: Expr.Struct) -> CostEstimate {
    var sum = CostEstimate.zero
    for field in s.fields {
      sum = sum.adding(cost(field.value))
    }
    return sum.adding(createMessageBaseCost)
  }

  private mutating func costComprehension(_ e: Expr, _ comp: Expr.Comprehension) -> CostEstimate {
    var sum = CostEstimate.zero
    sum = sum.adding(cost(comp.iterRange))
    sum = sum.adding(cost(comp.accuInit))
    pushLocalVar(comp.accuVar, comp.accuInit)

    // Track the range of each iteration variable for field paths.
    if comp.hasIterVar2 {
      pushIterKey(comp.iterVar, comp.iterRange)
      pushIterValue(comp.iterVar2, comp.iterRange)
    } else {
      pushIterSingle(comp.iterVar, comp.iterRange)
    }

    // The cost of each iteration.
    let loopCost = cost(comp.loopCondition)
    let stepCost = cost(comp.loopStep)

    popLocalVar(comp.iterVar)
    if comp.hasIterVar2 {
      popLocalVar(comp.iterVar2)
    }

    sum = sum.adding(cost(comp.result))
    popLocalVar(comp.accuVar)

    // The cost of the loop.
    let rangeCount = sizeOrUnknown(comp.iterRange)
    let rangeCost = rangeCount.multiplied(byCost: stepCost.adding(loopCost))
    sum = sum.adding(rangeCost)

    switch comp.accuInit.kind {
    case .literal:
      setSize(e, computeSize(comp.accuInit))
    case .list, .map:
      setSize(e, rangeCount)
      // A step producing a container has an entry size for its expression id.
      if let stepEntrySize = computeEntrySize(comp.loopStep) {
        setEntrySize(e, stepEntrySize)
      }
    default:
      break
    }
    return sum
  }

  private func isBind(_ comp: Expr.Comprehension) -> Bool {
    guard case .list(let range) = comp.iterRange.kind, range.elements.isEmpty,
      case .literal(.bool(false)) = comp.loopCondition.kind
    else {
      return false
    }
    return comp.accuVar != Macro.accumulatorName
  }

  private mutating func costBind(_ e: Expr, _ comp: Expr.Comprehension) -> CostEstimate {
    var sum = CostEstimate.zero
    // Binds are lazily initialized, so the cost of the empty range is kept.
    sum = sum.adding(cost(comp.iterRange))
    sum = sum.adding(cost(comp.accuInit))

    pushLocalVar(comp.accuVar, comp.accuInit)
    sum = sum.adding(cost(comp.result))
    popLocalVar(comp.accuVar)

    // The bind's size is the result's.
    copySizeEstimates(e, comp.result)
    return sum
  }

  private mutating func functionCost(
    _ e: Expr, function: String, overloadID: String, target: CostAstNode?, args: [CostAstNode],
    argCosts: [CostEstimate]
  ) -> CallEstimate {
    func argCostSum() -> CostEstimate {
      argCosts.reduce(CostEstimate.zero) { $0.adding($1) }
    }
    if let fn = overloadEstimators[overloadID], let est = fn(estimator, target, args) {
      return CallEstimate(cost: est.cost.adding(argCostSum()), resultSize: est.resultSize)
    }
    if let est = estimator.estimateCallCost(function: function, overloadID: overloadID, target: target, args: args) {
      return CallEstimate(cost: est.cost.adding(argCostSum()), resultSize: est.resultSize)
    }
    let f = Cost.stringTraversalCostFactor
    switch overloadID {
    // O(n) functions
    case Overloads.extFormatString:
      if let target {
        // No result size: the maximum cannot be bounded.
        return CallEstimate(cost: sizeOrUnknown(target).multipliedByCostFactor(f).adding(argCostSum()))
      }
    case Overloads.stringToBytes:
      if args.count == 1 {
        let sz = sizeOrUnknown(args[0])
        // At most four bytes per code point.
        return CallEstimate(
          cost: sz.multipliedByCostFactor(f).adding(argCostSum()),
          resultSize: SizeEstimate(min: sz.min, max: sz.max &* 4))
      }
    case Overloads.bytesToString:
      if args.count == 1 {
        let sz = sizeOrUnknown(args[0])
        // At least one code point per four bytes.
        return CallEstimate(
          cost: sz.multipliedByCostFactor(f).adding(argCostSum()),
          resultSize: SizeEstimate(min: sz.min / 4, max: sz.max))
      }
    case Overloads.extQuoteString:
      if args.count == 1 {
        let sz = sizeOrUnknown(args[0])
        // Every code point may be escaped; two quotes are always added.
        return CallEstimate(
          cost: sz.multipliedByCostFactor(f).adding(argCostSum()),
          resultSize: SizeEstimate(min: sz.min &+ 2, max: sz.max &* 2 &+ 2))
      }
    case Overloads.startsWithString, Overloads.endsWithString:
      if args.count == 1 {
        return CallEstimate(cost: sizeOrUnknown(args[0]).multipliedByCostFactor(f).adding(argCostSum()))
      }
    case Overloads.inList:
      // Assumes every list membership test is O(n), even for constant lists.
      if args.count == 2 {
        return CallEstimate(cost: sizeOrUnknown(args[1]).multipliedByCostFactor(1).adding(argCostSum()))
      }
    // O(nm) functions
    case Overloads.matches, Overloads.matchesString:
      // https://swtch.com/~rsc/regexp/regexp1.html applies to the RE2 semantics CEL requires.
      var strNode: CostAstNode?
      var regexNode: CostAstNode?
      if overloadID == Overloads.matchesString, let target, args.count == 1 {
        strNode = target
        regexNode = args[0]
      } else if overloadID == Overloads.matches, target == nil, args.count == 2 {
        strNode = args[0]
        regexNode = args[1]
      }
      if let strNode, let regexNode {
        // One is added to the string length so an expensive regex on an empty string still costs.
        let strCost = sizeOrUnknown(strNode).adding(.fixed(1)).multipliedByCostFactor(f)
        // Assumes each regex expression is at least four characters long.
        let regexCost = sizeOrUnknown(regexNode).multipliedByCostFactor(Cost.regexStringLengthCostFactor)
        return CallEstimate(cost: strCost.multiplied(by: regexCost).adding(argCostSum()))
      }
    case Overloads.containsString:
      if let target, args.count == 1 {
        let strCost = sizeOrUnknown(target).multipliedByCostFactor(f)
        let substrCost = sizeOrUnknown(args[0]).multipliedByCostFactor(f)
        return CallEstimate(cost: strCost.multiplied(by: substrCost).adding(argCostSum()))
      }
    case Overloads.logicalOr, Overloads.logicalAnd:
      // The minimum is the left-hand side alone, short-circuited.
      let lhs = argCosts[0]
      let rhs = argCosts[1]
      return CallEstimate(cost: CostEstimate(min: lhs.min, max: lhs.adding(rhs).max))
    case Overloads.conditional:
      let size = sizeOrUnknown(args[1]).union(sizeOrUnknown(args[2]))
      if let t = args[1].expr, let f = args[2].expr {
        setEntrySize(e, computeEntrySize(t).union(computeEntrySize(f)))
      }
      let argCost = argCosts[0].adding(argCosts[1].union(argCosts[2]))
      return CallEstimate(cost: argCost, resultSize: size)
    case Overloads.addString, Overloads.addBytes, Overloads.addList:
      if args.count == 2 {
        let lhsSize = sizeOrUnknown(args[0])
        let rhsSize = sizeOrUnknown(args[1])
        let resultSize = lhsSize.adding(rhsSize)
        if let l = args[0].expr, let r = args[1].expr,
          let entrySize = computeEntrySize(l).union(computeEntrySize(r))
        {
          setEntrySize(e, entrySize)
        }
        if overloadID == Overloads.addList {
          // List concatenation is O(1); handled here to track the size.
          return CallEstimate(cost: CostEstimate.fixed(1).adding(argCostSum()), resultSize: resultSize)
        }
        return CallEstimate(
          cost: resultSize.multipliedByCostFactor(f).adding(argCostSum()), resultSize: resultSize)
      }
    case Overloads.lessString, Overloads.greaterString, Overloads.lessEqualsString, Overloads.greaterEqualsString,
      Overloads.lessBytes, Overloads.greaterBytes, Overloads.lessEqualsBytes, Overloads.greaterEqualsBytes,
      Overloads.equals, Overloads.notEquals:
      let lhsCost = sizeOrUnknown(args[0])
      let rhsCost = sizeOrUnknown(args[1])
      let smallestMax = Swift.min(lhsCost.max, rhsCost.max)
      let minCost: UInt64 = smallestMax > 0 ? 1 : 0
      // Equality of two scalars costs 1.
      return CallEstimate(
        cost: CostEstimate(min: minCost, max: smallestMax).multipliedByCostFactor(f).adding(argCostSum()))
    default:
      break
    }
    // O(1) functions, see CostTracker.costCall. Benchmarks suggest most other operations take
    // about one base cost unit.
    return CallEstimate(cost: CostEstimate.fixed(1).adding(argCostSum()))
  }

  // MARK: Paths and sizes

  /// The deduced type of an expression; `dyn` when the checker recorded none (cel-go `GetType`).
  private func type(of e: Expr) -> CELType {
    checked.typeMap[e.id] ?? .dyn
  }

  private func path(of e: Expr) -> [String] {
    if case .ident(let name) = e.kind, let v = peekLocalVar(name) {
      return v.path
    }
    return exprPaths[e.id] ?? []
  }

  private mutating func addPath(_ e: Expr, _ path: [String]) {
    exprPaths[e.id] = path
  }

  private mutating func newAstNode(_ e: Expr) -> CostAstNode {
    var p = path(of: e)
    if let first = p.first, first == Macro.accumulatorName || first == Macro.hiddenAccumulatorName {
      // Paths are only given for root variables, not accumulators.
      p = []
    }
    return CostAstNode(path: p, type: type(of: e), expr: e, computedSize: computeSize(e))
  }

  private mutating func setSize(_ e: Expr, _ size: SizeEstimate?) {
    if let size {
      computedSizes[e.id] = size
    }
  }

  private mutating func sizeOrUnknown(_ e: Expr) -> SizeEstimate {
    computeSize(e) ?? .unknown
  }

  private func sizeOrUnknown(_ node: CostAstNode) -> SizeEstimate {
    node.computedSize ?? .unknown
  }

  private mutating func copySizeEstimates(_ dst: Expr, _ src: Expr) {
    setSize(dst, computeSize(src))
    setEntrySize(dst, computeEntrySize(src))
  }

  private mutating func computeSize(_ e: Expr) -> SizeEstimate? {
    if let size = computedSizes[e.id] {
      return size
    }
    if let size = computeExprSize(e) {
      return size
    }
    // Ask the estimator before using the type, so users can override the sizes CEL would derive.
    let node = CostAstNode(path: path(of: e), type: type(of: e), expr: e)
    if let size = estimator.estimateSize(node) {
      computedSizes[e.id] = size
      return size
    }
    if let size = computeTypeSize(type(of: e)) {
      return size
    }
    if case .ident(let name) = e.kind, let v = peekLocalVar(name), let size = v.size {
      return size
    }
    return nil
  }

  private mutating func setEntrySize(_ e: Expr, _ size: EntrySizeEstimate?) {
    if let size {
      computedEntrySizes[e.id] = size
    }
  }

  private func computeEntrySize(_ e: Expr) -> EntrySizeEstimate? {
    if let size = computedEntrySizes[e.id] {
      return size
    }
    if case .ident(let name) = e.kind, let v = peekLocalVar(name), let size = v.entrySize {
      return size
    }
    return nil
  }
}

/// The exact size of a literal, list or map expression (cel-go `computeExprSize`).
private func computeExprSize(_ e: Expr) -> SizeEstimate? {
  switch e.kind {
  case .literal(let c):
    switch c {
    case .string(let s):
      // Code points, as the runtime and the language definition count them.
      return .fixed(UInt64(s.unicodeScalars.count))
    case .bytes(let b):
      return .fixed(UInt64(b.count))
    case .bool, .double, .int, .uint, .null:
      return .fixed(1)
    }
  case .list(let l):
    return .fixed(UInt64(l.elements.count))
  case .map(let m):
    return .fixed(UInt64(m.entries.count))
  default:
    return nil
  }
}

/// The size of a value of a fixed-size type (cel-go `computeTypeSize`).
private func computeTypeSize(_ t: CELType) -> SizeEstimate? {
  isScalar(t) ? .fixed(1) : nil
}

/// Whether values of the type have a size known at compile time; strings, `Any` and `Value` do not
/// (cel-go `isScalar`).
private func isScalar(_ t: CELType) -> Bool {
  switch t.kind {
  case .bool, .double, .duration, .int, .timestamp, .uint:
    return true
  case .opaque:
    if t.runtimeTypeName == "optional_type", let param = t.parameters.first {
      return isScalar(param)
    }
    return false
  default:
    return false
  }
}

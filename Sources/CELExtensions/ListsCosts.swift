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
//
// Ported from cel-go ext/lists.go: the cost estimators and trackers of the lists library (version 3
// and later; version 3 keeps the legacy `flatten`, `distinct` and sort estimates).

import CEL

enum ListsCosts {
  /// Estimators by overload id (cel-go `listsLib.CompileOptions`).
  static func estimators(version: UInt32) -> [String: FunctionEstimator] {
    var result: [String: FunctionEstimator] = [
      "list_slice": estimateSlice,
      "lists_range": estimateRange,
      "list_reverse": estimateReverse,
    ]
    let legacy = version == 3
    result["list_flatten"] = legacy ? estimateFlattenLegacy : estimateFlatten
    result["list_flatten_int"] = legacy ? estimateFlattenLegacy : estimateFlatten
    result["list_distinct"] = legacy ? estimateDistinctLegacy : estimateDistinct
    for t in ListsLibrary.comparableTypes {
      result["list_\(t.runtimeTypeName)_sort"] = legacy ? estimateSortLegacy(t) : estimateSort(t)
      result["list_\(t.runtimeTypeName)_sortByAssociatedKeys"] = legacy ? estimateSortByLegacy(t) : estimateSortBy(t)
    }
    return result
  }

  /// Trackers by overload id (cel-go `listsLib.ProgramOptions`).
  static func trackers(version: UInt32) -> [String: FunctionTracker] {
    var result: [String: FunctionTracker] = [
      "list_slice": trackOutputSize,
      "lists_range": trackOutputSize,
      "list_reverse": trackOutputSize,
      "list_distinct": trackDistinct,
    ]
    let legacy = version == 3
    result["list_flatten"] = legacy ? trackFlattenLegacy : trackFlatten
    result["list_flatten_int"] = legacy ? trackFlattenLegacy : trackFlatten
    for t in ListsLibrary.comparableTypes {
      result["list_\(t.runtimeTypeName)_sort"] = trackSort
      result["list_\(t.runtimeTypeName)_sortByAssociatedKeys"] = trackSortBy
    }
    return result
  }

  // MARK: Estimators

  /// An O(n) slice with a cost factor of 1 (cel-go `estimateListSlice`).
  @Sendable static func estimateSlice(
    _ estimator: any CostEstimator, _ target: CostAstNode?, _ args: [CostAstNode]
  ) -> CallEstimate? {
    guard let target, args.count == 2 else { return nil }
    let size = estimateSize(estimator, target)
    let start = nodeAsUIntValue(args[0], default: 0)
    let end = nodeAsUIntValue(args[1], default: size.max)
    // Go's uint64 subtraction wraps when start > end.
    return estimateAllocatingListCall(1, .fixed(end &- start))
  }

  /// An O(n) range with a cost factor of 1 (cel-go `estimateListsRange`).
  @Sendable static func estimateRange(
    _ estimator: any CostEstimator, _ target: CostAstNode?, _ args: [CostAstNode]
  ) -> CallEstimate? {
    guard target == nil, args.count == 1 else { return nil }
    return estimateAllocatingListCall(1, .fixed(nodeAsUIntValue(args[0], default: .max)))
  }

  /// An O(n) reverse with a cost factor of 1 (cel-go `estimateListReverse`).
  @Sendable static func estimateReverse(
    _ estimator: any CostEstimator, _ target: CostAstNode?, _ args: [CostAstNode]
  ) -> CallEstimate? {
    guard let target, args.isEmpty else { return nil }
    return estimateAllocatingListCall(1, estimateSize(estimator, target))
  }

  /// An O(n) flatten proportional to the number of flattened items (cel-go `estimateListFlatten`).
  @Sendable static func estimateFlatten(
    _ estimator: any CostEstimator, _ target: CostAstNode?, _ args: [CostAstNode]
  ) -> CallEstimate? {
    guard let target, args.count <= 1 else { return nil }
    var depth: UInt64 = 1
    if args.count == 1 {
      depth = nodeAsUIntValue(args[0], default: .max)
    }
    let resultSize: SizeEstimate
    if let expr = target.expr, case .list = expr.kind {
      resultSize = .fixed(estimateLiteralFlattenSize(expr, depth: depth))
    } else {
      resultSize = estimateFlattenSize(estimator, target, depth: depth)
    }
    return estimateListCallWithDirectCost(resultSize.asCost, resultSize, allocates: true)
  }

  /// cel-go `estimateListFlattenLegacy` (version 3).
  @Sendable static func estimateFlattenLegacy(
    _ estimator: any CostEstimator, _ target: CostAstNode?, _ args: [CostAstNode]
  ) -> CallEstimate? {
    guard let target, args.count <= 1 else { return nil }
    var depth: UInt64 = 1
    if args.count == 1 {
      depth = nodeAsUIntValue(args[0], default: .max)
    }
    return estimateAllocatingListCall(Double(depth), estimateSize(estimator, target))
  }

  /// The size of a list flattened `depth` levels, from the sizes of its nested elements (cel-go
  /// `estimateFlattenSize`).
  static func estimateFlattenSize(_ estimator: any CostEstimator, _ node: CostAstNode, depth: UInt64) -> SizeEstimate {
    let size = estimateSize(estimator, node)
    if depth == 0 {
      return size
    }
    guard case .list(let elemType) = node.type else {
      return size
    }
    let elemNode = CostAstNode(path: node.path + ["@items"], type: elemType, expr: nil)
    return size.multiplied(by: estimateFlattenSize(estimator, elemNode, depth: depth - 1))
  }

  /// The exact size of a list literal flattened `depth` levels (cel-go
  /// `estimateLiteralFlattenSize`; the sum wraps as Go's does).
  static func estimateLiteralFlattenSize(_ expr: Expr, depth: UInt64) -> UInt64 {
    guard case .list(let list) = expr.kind else {
      return 1
    }
    if depth == 0 {
      return UInt64(list.elements.count)
    }
    var total: UInt64 = 0
    for element in list.elements {
      total &+= estimateLiteralFlattenSize(element, depth: depth - 1)
    }
    return total
  }

  /// O(n^2) with a cost factor of 2, as `sets.contains` with a result of one element up to the
  /// list's size (cel-go `estimateListDistinct`).
  @Sendable static func estimateDistinct(
    _ estimator: any CostEstimator, _ target: CostAstNode?, _ args: [CostAstNode]
  ) -> CallEstimate? {
    guard let target, args.isEmpty else { return nil }
    let size = estimateSize(estimator, target)
    var elemType = CELType.dyn
    if case .list(let t) = target.type {
      elemType = t
    }
    let itemSize = estimateItemSize(estimator, target)
    let elemCost = estimateElementEqualityCost(elemType, itemSize)
    let cost = size.multiplied(by: size).multiplied(byCost: elemCost).multipliedByCostFactor(2)
    let resultSize = SizeEstimate(min: size.min > 0 ? 1 : 0, max: size.max)
    return estimateListCallWithDirectCost(cost, resultSize, allocates: true)
  }

  /// An O(n^2) sort with a cost factor of 2 for the comparisons (cel-go `estimateListSort`).
  static func estimateSort(_ t: CELType) -> FunctionEstimator {
    { estimator, target, args in
      guard let target, args.isEmpty else { return nil }
      return estimateSortCost(estimator, target, elemType: t)
    }
  }

  /// An O(n^2) sort over the sort keys with a cost factor of 2 (cel-go `estimateListSortBy`).
  static func estimateSortBy(_ u: CELType) -> FunctionEstimator {
    { estimator, target, args in
      guard let target, args.count == 1 else { return nil }
      // The keys list's size; the target resolves the item size hints.
      let size = estimateSize(estimator, args[0])
      let itemSize = estimateItemSize(estimator, target)
      let elemCost = estimateElementEqualityCost(u, itemSize)
      let cost = size.multiplied(by: size).multiplied(byCost: elemCost).multipliedByCostFactor(2)
      return estimateListCallWithDirectCost(cost, size, allocates: true)
    }
  }

  /// cel-go `estimateListSortCost`.
  static func estimateSortCost(_ estimator: any CostEstimator, _ node: CostAstNode, elemType: CELType) -> CallEstimate {
    let size = estimateSize(estimator, node)
    let itemSize = estimateItemSize(estimator, node)
    let elemCost = estimateElementEqualityCost(elemType, itemSize)
    let cost = size.multiplied(by: size).multiplied(byCost: elemCost).multipliedByCostFactor(2)
    return estimateListCallWithDirectCost(cost, size, allocates: true)
  }

  /// cel-go `estimateListDistinctLegacy` (version 3).
  @Sendable static func estimateDistinctLegacy(
    _ estimator: any CostEstimator, _ target: CostAstNode?, _ args: [CostAstNode]
  ) -> CallEstimate? {
    guard let target, args.isEmpty else { return nil }
    let size = estimateSize(estimator, target)
    var costFactor = 2.0
    if case .list(let elemType) = target.type, elemType.kind == .string || elemType.kind == .bytes {
      costFactor += Cost.stringTraversalCostFactor
    }
    return estimateAllocatingListCall(costFactor, size.multiplied(by: size))
  }

  /// cel-go `estimateListSortLegacy` (version 3).
  static func estimateSortLegacy(_ t: CELType) -> FunctionEstimator {
    { estimator, target, args in
      guard let target, args.isEmpty else { return nil }
      return estimateSortCostLegacy(estimator, target, elemType: t)
    }
  }

  /// cel-go `estimateListSortByLegacy` (version 3): sized by the keys list.
  static func estimateSortByLegacy(_ u: CELType) -> FunctionEstimator {
    { estimator, target, args in
      guard target != nil, args.count == 1 else { return nil }
      return estimateSortCostLegacy(estimator, args[0], elemType: u)
    }
  }

  /// cel-go `estimateListSortCostLegacy`.
  static func estimateSortCostLegacy(_ estimator: any CostEstimator, _ node: CostAstNode, elemType: CELType)
    -> CallEstimate
  {
    let size = estimateSize(estimator, node)
    var costFactor = 2.0
    if elemType == .string || elemType == .bytes {
      costFactor += Cost.stringTraversalCostFactor
    }
    return estimateAllocatingListCall(costFactor, size.multiplied(by: size))
  }

  /// The size of the list's elements from the estimator's `@items` hint, else unknown (cel-go
  /// `estimateItemSize`).
  static func estimateItemSize(_ estimator: any CostEstimator, _ node: CostAstNode) -> SizeEstimate {
    if node.path.isEmpty {
      return .unknown
    }
    var elemType = CELType.dyn
    if case .list(let t) = node.type {
      elemType = t
    }
    let itemNode = CostAstNode(path: node.path + ["@items"], type: elemType, expr: nil)
    return estimator.estimateSize(itemNode) ?? .unknown
  }

  /// The cost of comparing two elements of the type (cel-go `estimateElementEqualityCost`).
  static func estimateElementEqualityCost(_ elemType: CELType, _ itemSize: SizeEstimate) -> CostEstimate {
    switch elemType.kind {
    case .string, .bytes:
      return itemSize.multipliedByCostFactor(Cost.stringTraversalCostFactor)
    case .list, .map, .struct:
      return .unknown
    default:
      return .fixed(1)
    }
  }

  /// The cost of a call allocating a list of the given size (cel-go `estimateAllocatingListCall`).
  static func estimateAllocatingListCall(_ costFactor: Double, _ listSize: SizeEstimate) -> CallEstimate {
    estimateListCallWithDirectCost(listSize.multipliedByCostFactor(costFactor), listSize, allocates: true)
  }

  /// cel-go `estimateListCallWithDirectCost`.
  static func estimateListCallWithDirectCost(_ cost: CostEstimate, _ resultSize: SizeEstimate, allocates: Bool)
    -> CallEstimate
  {
    var cost = cost
    if allocates {
      cost = cost.adding(.fixed(Cost.listCreateBaseCost))
    }
    return CallEstimate(cost: cost.adding(callCostEstimate), resultSize: resultSize)
  }

  // MARK: Trackers

  /// The size of the result list (cel-go `trackListOutputSize`).
  @Sendable static func trackOutputSize(_ args: [Value], _ result: Value) -> UInt64? {
    trackAllocatingListCall(1, extActualSize(result))
  }

  /// The size of the result list (cel-go `trackListFlatten`).
  @Sendable static func trackFlatten(_ args: [Value], _ result: Value) -> UInt64? {
    trackAllocatingListCall(1, extActualSize(result))
  }

  /// The input size times the depth (cel-go `trackListFlattenLegacy`, version 3).
  @Sendable static func trackFlattenLegacy(_ args: [Value], _ result: Value) -> UInt64? {
    var depth = 1.0
    if args.count == 2, case .int(let d) = args[1] {
      depth = Double(d)
    }
    return trackAllocatingListCall(depth, extActualSize(args[0]))
  }

  /// O(n^2) over the input list (cel-go `trackListDistinct`).
  @Sendable static func trackDistinct(_ args: [Value], _ result: Value) -> UInt64? {
    trackSelfCompare(args[0])
  }

  /// O(n^2) over the input list (cel-go `trackListSort`).
  @Sendable static func trackSort(_ args: [Value], _ result: Value) -> UInt64? {
    trackSelfCompare(args[0])
  }

  /// O(n^2) over the sort keys (cel-go `trackListSortBy`).
  @Sendable static func trackSortBy(_ args: [Value], _ result: Value) -> UInt64? {
    trackSelfCompare(args[1])
  }

  /// Worst-case O(n^2) comparisons of the list's elements (cel-go `trackListSelfCompare`).
  static func trackSelfCompare(_ list: Value) -> UInt64 {
    let size = extActualSize(list)
    var costFactor = 2.0
    guard size > 0, case .list(let l) = list else {
      return trackAllocatingListCall(costFactor, 0)
    }
    switch l.element(at: 0) {
    case .string, .bytes: costFactor += Cost.stringTraversalCostFactor
    default: break
    }
    return trackAllocatingListCall(costFactor, Cost.safeMultiply(size, size))
  }

  /// The result size times the factor plus the call and the list allocation (cel-go
  /// `trackAllocatingListCall`).
  static func trackAllocatingListCall(_ costFactor: Double, _ size: UInt64) -> UInt64 {
    let costFactor = costFactor < 0 ? 1 : costFactor
    return Cost.safeAdd(goUInt64(Double(size) * costFactor), callCost, Cost.listCreateBaseCost)
  }
}

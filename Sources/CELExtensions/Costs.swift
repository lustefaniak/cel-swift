// Copyright 2026 Google LLC
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
// Ported from cel-go ext/costs.go: helpers shared by the extension libraries' static cost
// estimators (cel-go `checker.FunctionEstimator`) and runtime cost trackers (cel-go
// `interpreter.FunctionTracker`).
//
// cel-go's size arithmetic is partly saturating (`cost.SafeAdd`, `SizeEstimate.Add`, ...) and partly
// plain `uint64` arithmetic, which wraps on overflow; the ports keep each as it is, with `&+`, `&-`
// and `&*` where cel-go wraps.

import CEL

let callCostEstimate = CostEstimate.fixed(1)
let callCost: UInt64 = 1
let listAllocCost = CostEstimate.fixed(Cost.listCreateBaseCost)
let stringCostFactor = Cost.stringTraversalCostFactor

/// The cost of scanning a string of the given size, and the size (cel-go `estimateStringScan`).
func estimateStringScan(_ size: SizeEstimate) -> (CostEstimate, SizeEstimate) {
  estimateTraversal(size, costFactor: stringCostFactor, allocationCost: nil)
}

/// The cost of allocating a list of the given size (cel-go `estimateListAlloc`).
func estimateListAlloc(_ size: SizeEstimate, costFactor: Double) -> (CostEstimate, SizeEstimate) {
  estimateTraversal(size, costFactor: costFactor, allocationCost: listAllocCost)
}

/// The cost as a function of the size of the target object and whether the call allocates
/// (cel-go `estimateTraversal`).
func estimateTraversal(_ nodeSize: SizeEstimate, costFactor: Double, allocationCost: CostEstimate?)
  -> (CostEstimate, SizeEstimate)
{
  var cost = nodeSize.multipliedByCostFactor(costFactor)
  if let allocationCost {
    cost = cost.adding(allocationCost)
  }
  return (cost, nodeSize)
}

/// The size of a node: computed from the expression, else from the estimator, else unknown
/// (cel-go `estimateSize`).
func estimateSize(_ estimator: any CostEstimator, _ node: CostAstNode) -> SizeEstimate {
  if let size = node.computedSize {
    return size
  }
  if let size = estimator.estimateSize(node) {
    return size
  }
  return .unknown
}

/// The size of a value for the extension trackers: CEL's `size()` of strings, bytes, lists and
/// maps, the byte size of IP addresses and CIDR prefixes, else 1 (cel-go ext `actualSize`, which,
/// unlike the interpreter's, does not look inside optionals).
func extActualSize(_ value: Value) -> UInt64 {
  switch value {
  case .string, .bytes, .list, .map:
    if case .int(let n) = value.size() {
      return UInt64(truncatingIfNeeded: n)
    }
    return 1
  case .object(let object):
    if let sized = object as? any CostSizedValue {
      return sized.costSize
    }
    return 1
  default:
    return 1
  }
}

/// The value of a non-negative int literal node as a `UInt64`, 0 for a negative one, or the default
/// when the node is not an int literal (cel-go `nodeAsUintValue`).
func nodeAsUIntValue(_ node: CostAstNode, default defaultValue: UInt64) -> UInt64 {
  guard let expr = node.expr, case .literal(.int(let value)) = expr.kind else {
    return defaultValue
  }
  return value < 0 ? 0 : UInt64(value)
}

/// A call estimate (cel-go `callEstimate`).
func callEstimate(_ cost: CostEstimate, _ size: SizeEstimate?) -> CallEstimate {
  CallEstimate(cost: cost, resultSize: size)
}

/// A size range (cel-go `rangedSizeEstimate`).
func rangedSizeEstimate(_ min: UInt64, _ max: UInt64) -> SizeEstimate {
  SizeEstimate(min: min, max: max)
}

/// The size with a zero minimum or maximum raised to 1 (cel-go `atLeastOne`).
func atLeastOne(_ size: SizeEstimate) -> SizeEstimate {
  var size = size
  if size.min == 0 {
    size.min = 1
  }
  if size.max == 0 {
    size.max = 1
  }
  return size
}

/// A cost estimate with the bounds of a size estimate (cel-go's `checker.CostEstimate(size)`
/// conversion, which, unlike `AsCost`, is not rounded through a cost factor).
func costEstimate(_ size: SizeEstimate) -> CostEstimate {
  CostEstimate(min: size.min, max: size.max)
}

/// Go's `uint64(f)` for a float: truncation toward zero. Go leaves out-of-range conversions to the
/// platform; this follows arm64 (the oracle's platform), which saturates: NaN and negative values
/// give 0, values of 2^64 and above `UInt64.max`.
func goUInt64(_ f: Double) -> UInt64 {
  if f.isNaN || f <= 0 {
    return 0
  }
  if f >= 18_446_744_073_709_551_616.0 {
    return .max
  }
  return UInt64(f)
}

/// Go's `uint64(math.Ceil(f))`, saturating as ``goUInt64(_:)``.
func goCeilUInt64(_ f: Double) -> UInt64 {
  goUInt64(f.rounded(.up))
}

extension Library {
  /// The library with cost estimators and trackers added (cel-go `CostEstimatorOptions` with
  /// `OverloadCostEstimate`, and `CostTrackerOptions` with `OverloadCostTracker`).
  func withCosts(estimators: [String: FunctionEstimator], trackers: [String: FunctionTracker]) -> Library {
    var lib = self
    lib.costEstimateOptions.overloadEstimators.merge(estimators) { _, new in new }
    lib.costTrackers.merge(trackers) { _, new in new }
    return lib
  }
}

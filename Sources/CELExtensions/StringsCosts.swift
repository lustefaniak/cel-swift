// Copyright 2020 Google LLC
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
// Ported from cel-go ext/strings.go: the cost estimators and trackers of the strings library
// (version 5 and later). Static estimates are proportional to the sizes of the input strings;
// runtime costs use the actual sizes of the inputs and the result.

import CEL

enum StringsCosts {
  /// Estimators by overload id (cel-go `CompileOptions`, version 5).
  static let estimators: [String: FunctionEstimator] = [
    "string_char_at_int": estimateCharAt,
    "string_index_of_string": estimateSearch,
    "string_index_of_string_int": estimateSearch,
    "string_last_index_of_string": estimateSearch,
    "string_last_index_of_string_int": estimateSearch,
    "string_lower_ascii": estimateFixedTransform,
    "string_upper_ascii": estimateFixedTransform,
    "string_replace_string_string": estimateReplace,
    "string_replace_string_string_int": estimateReplace,
    "string_split_string": estimateSplit,
    "string_split_string_int": estimateSplit,
    "string_substring_int": estimateSubstring,
    "string_substring_int_int": estimateSubstring,
    "string_trim": estimateVariableTransform,
    "string_reverse": estimateFixedTransform,
    "list_join": estimateJoin,
    "list_join_string": estimateJoin,
  ]

  /// Trackers by overload id (cel-go `ProgramOptions`, version 5).
  static let trackers: [String: FunctionTracker] = [
    "string_char_at_int": trackCharAt,
    "string_index_of_string": trackSearch,
    "string_index_of_string_int": trackSearch,
    "string_last_index_of_string": trackSearch,
    "string_last_index_of_string_int": trackSearch,
    "string_lower_ascii": trackTransform,
    "string_upper_ascii": trackTransform,
    "string_replace_string_string": trackReplace,
    "string_replace_string_string_int": trackReplace,
    "string_split_string": trackSplit,
    "string_split_string_int": trackSplit,
    "string_substring_int": trackTransform,
    "string_substring_int_int": trackTransform,
    "string_trim": trackTransform,
    "string_reverse": trackTransform,
    "list_join": trackJoin,
    "list_join_string": trackJoin,
  ]

  // MARK: Estimators

  /// O(n) operations producing a string of the input's size, such as `lowerAscii`, `upperAscii`
  /// and `reverse` (cel-go `estimateStringFixedTransformCost`).
  @Sendable static func estimateFixedTransform(
    _ estimator: any CostEstimator, _ target: CostAstNode?, _ args: [CostAstNode]
  ) -> CallEstimate? {
    guard let target else { return nil }
    let (cost, size) = estimateStringScan(estimateSize(estimator, target))
    return callEstimate(cost.adding(callCostEstimate).adding(size.asCost), size)
  }

  /// O(n) operations producing a string from empty up to the input's size, such as `trim`
  /// (cel-go `estimateStringVariableTransformCost`).
  @Sendable static func estimateVariableTransform(
    _ estimator: any CostEstimator, _ target: CostAstNode?, _ args: [CostAstNode]
  ) -> CallEstimate? {
    guard let target else { return nil }
    let (cost, size) = estimateStringScan(estimateSize(estimator, target))
    let transformSize = rangedSizeEstimate(0, size.max)
    return callEstimate(cost.adding(callCostEstimate).adding(transformSize.asCost), transformSize)
  }

  /// The traversal plus one for the allocation (cel-go `estimateStringCharAtCost`).
  @Sendable static func estimateCharAt(
    _ estimator: any CostEstimator, _ target: CostAstNode?, _ args: [CostAstNode]
  ) -> CallEstimate? {
    guard let target, args.count == 1 else { return nil }
    let (cost, _) = estimateStringScan(estimateSize(estimator, target))
    return callEstimate(cost.adding(callCostEstimate).adding(callCostEstimate), rangedSizeEstimate(0, 1))
  }

  /// An O(n) traversal and allocation (cel-go `estimateSubstringCost`).
  @Sendable static func estimateSubstring(
    _ estimator: any CostEstimator, _ target: CostAstNode?, _ args: [CostAstNode]
  ) -> CallEstimate? {
    guard let target, (1...2).contains(args.count) else { return nil }
    let targetSize = estimateSize(estimator, target)
    let (cost, _) = estimateStringScan(targetSize)
    let start = nodeAsUIntValue(args[0], default: 0)
    var end = targetSize.max
    if args.count == 2 {
      end = nodeAsUIntValue(args[1], default: end)
    }
    // Go's uint64 subtraction wraps when start > end.
    let resultSize = SizeEstimate.fixed(end &- start)
    return callEstimate(cost.adding(callCostEstimate).adding(resultSize.asCost), resultSize)
  }

  /// O(n*m) searches such as `indexOf` and `lastIndexOf` (cel-go `estimateStringSearchCost`).
  @Sendable static func estimateSearch(
    _ estimator: any CostEstimator, _ target: CostAstNode?, _ args: [CostAstNode]
  ) -> CallEstimate? {
    guard let target, !args.isEmpty else { return nil }
    let targetSize = estimateSize(estimator, target)
    let needleSize = estimateSize(estimator, args[0])
    let (searchCost, _) = estimateStringScan(targetSize.multiplied(by: needleSize))
    return callEstimate(searchCost.adding(callCostEstimate), nil)
  }

  /// The search, O(n*m), and the growth of the output (cel-go `estimateStringReplaceCost`).
  @Sendable static func estimateReplace(
    _ estimator: any CostEstimator, _ target: CostAstNode?, _ args: [CostAstNode]
  ) -> CallEstimate? {
    guard let target, args.count >= 2 else { return nil }
    let targetSize = estimateSize(estimator, target)
    let needleSize = atLeastOne(estimateSize(estimator, args[0]))
    let searchCost = atLeastOne(targetSize).multiplied(by: needleSize).multipliedByCostFactor(stringCostFactor)

    let replacementSize = estimateSize(estimator, args[1]).adding(.fixed(1))
    let allReplacedSize = Cost.safeMultiply(Cost.safeAdd(targetSize.max, 1), replacementSize.max)
    let resultMinSize = Swift.min(targetSize.min, replacementSize.min)
    let resultSize = rangedSizeEstimate(resultMinSize, allReplacedSize)
    return callEstimate(searchCost.adding(resultSize.asCost).adding(callCostEstimate), resultSize)
  }

  /// The traversal and the allocation of a list of up to one element per code point (cel-go
  /// `estimateStringSplitCost`).
  @Sendable static func estimateSplit(
    _ estimator: any CostEstimator, _ target: CostAstNode?, _ args: [CostAstNode]
  ) -> CallEstimate? {
    guard let target, !args.isEmpty else { return nil }
    let targetSize = estimateSize(estimator, target)
    let traversalCost = targetSize.adding(.fixed(1)).multipliedByCostFactor(stringCostFactor)
    // Worst case: split("") produces N elements for a string of size N.
    let resultSize = rangedSizeEstimate(0, targetSize.max)
    let allocationCost = resultSize.multipliedByCostFactor(1).adding(.fixed(Cost.listCreateBaseCost))
    let cost = traversalCost.adding(allocationCost).adding(callCostEstimate)
    return callEstimate(cost, resultSize)
  }

  /// The traversal of the list and the size of the joined string (cel-go `estimateStringJoinCost`).
  @Sendable static func estimateJoin(
    _ estimator: any CostEstimator, _ target: CostAstNode?, _ args: [CostAstNode]
  ) -> CallEstimate? {
    guard let target else { return nil }
    let targetSize = estimateSize(estimator, target)
    var sepSize = SizeEstimate.fixed(0)
    if !args.isEmpty {
      sepSize = estimateSize(estimator, args[0])
    }
    let traversalCost = targetSize.adding(.fixed(1)).multipliedByCostFactor(stringCostFactor)
    // Worst case: list size * max element size + list size * separator size.
    let maxResultSize = Cost.safeAdd(
      Cost.safeMultiply(targetSize.max, Cost.safeAdd(1, sepSize.max)), sepSize.max)
    let resultSize = rangedSizeEstimate(0, maxResultSize)
    let estimate = traversalCost.adding(resultSize.multipliedByCostFactor(1)).adding(callCostEstimate)
    return callEstimate(estimate, resultSize)
  }

  // MARK: Trackers

  /// cel-go `trackStringCharAtCost`.
  @Sendable static func trackCharAt(_ args: [Value], _ result: Value) -> UInt64? {
    Cost.safeAdd(callCost, Cost.safeMultiplyByFactor(extActualSize(args[0]), stringCostFactor), 1)
  }

  /// O(n) transforms: the traversal plus the size of the result (cel-go `trackStringTransformCost`).
  @Sendable static func trackTransform(_ args: [Value], _ result: Value) -> UInt64? {
    let transformCost = Cost.safeMultiplyByFactor(extActualSize(args[0]), stringCostFactor)
    return Cost.safeAdd(callCost, transformCost, extActualSize(result))
  }

  /// O(n*m) searches (cel-go `trackStringSearchCost`).
  @Sendable static func trackSearch(_ args: [Value], _ result: Value) -> UInt64? {
    let searchSize = Cost.safeMultiply(extActualSize(args[0]), extActualSize(args[1]))
    return Cost.safeAdd(Cost.safeMultiplyByFactor(searchSize, stringCostFactor), callCost)
  }

  /// The search plus the size of the result (cel-go `trackStringReplaceCost`).
  @Sendable static func trackReplace(_ args: [Value], _ result: Value) -> UInt64? {
    let targetSize = Swift.max(extActualSize(args[0]), 1)
    let needleSize = Swift.max(extActualSize(args[1]), 1)
    let searchCost = Cost.safeMultiplyByFactor(Cost.safeMultiply(targetSize, needleSize), stringCostFactor)
    return Cost.safeAdd(callCost, searchCost, extActualSize(result))
  }

  /// The traversal plus the list allocation (cel-go `trackStringSplitCost`).
  @Sendable static func trackSplit(_ args: [Value], _ result: Value) -> UInt64? {
    let traversalCost = Cost.safeMultiplyByFactor(Cost.safeAdd(extActualSize(args[0]), 1), stringCostFactor)
    return Cost.safeAdd(callCost, traversalCost, extActualSize(result), Cost.listCreateBaseCost)
  }

  /// The traversal plus the size of the result (cel-go `trackStringJoinCost`).
  @Sendable static func trackJoin(_ args: [Value], _ result: Value) -> UInt64? {
    let traversalCost = Cost.safeMultiplyByFactor(Cost.safeAdd(extActualSize(args[0]), 1), stringCostFactor)
    return Cost.safeAdd(callCost, traversalCost, extActualSize(result))
  }
}

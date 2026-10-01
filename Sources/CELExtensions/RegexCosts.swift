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
// Ported from cel-go ext/regex.go: the cost estimators and trackers of `regex.extract`,
// `regex.extractAll` and `regex.replace`.

import CEL

enum RegexCosts {
  /// Estimators by overload id.
  static let estimators: [String: FunctionEstimator] = [
    "regex_extract_string_string": estimateExtract,
    "regex_extractAll_string_string": estimateExtractAll,
    "regex_replace_string_string_string": estimateReplace,
    "regex_replace_string_string_string_int": estimateReplace,
  ]

  /// Trackers by overload id.
  static let trackers: [String: FunctionTracker] = [
    "regex_extract_string_string": trackExtract,
    "regex_extractAll_string_string": trackExtractAll,
    "regex_replace_string_string_string": trackReplace,
    "regex_replace_string_string_string_int": trackReplace,
  ]

  /// The target's traversal cost and the pattern's complexity cost, each over the size plus one
  /// so empty inputs still cost.
  private static func searchCosts(_ estimator: any CostEstimator, _ args: [CostAstNode])
    -> (target: CostEstimate, regex: CostEstimate)
  {
    let targetCost = estimateSize(estimator, args[0]).adding(.fixed(1))
      .multipliedByCostFactor(Cost.stringTraversalCostFactor)
    let regexCost = estimateSize(estimator, args[1]).adding(.fixed(1))
      .multipliedByCostFactor(Cost.regexStringLengthCostFactor)
    return (targetCost, regexCost)
  }

  /// The search plus a result of up to the target's size (cel-go `estimateExtractCost`).
  @Sendable static func estimateExtract(
    _ estimator: any CostEstimator, _ target: CostAstNode?, _ args: [CostAstNode]
  ) -> CallEstimate? {
    guard args.count == 2 else { return nil }
    let targetSize = estimateSize(estimator, args[0])
    let (targetCost, regexCost) = searchCosts(estimator, args)
    let resultSize = rangedSizeEstimate(0, targetSize.max)
    return callEstimate(regexCost.multiplied(by: targetCost).adding(costEstimate(resultSize)), resultSize)
  }

  /// The search plus a result list holding up to the target's size (cel-go
  /// `estimateExtractAllCost`).
  @Sendable static func estimateExtractAll(
    _ estimator: any CostEstimator, _ target: CostAstNode?, _ args: [CostAstNode]
  ) -> CallEstimate? {
    guard args.count == 2 else { return nil }
    let targetSize = estimateSize(estimator, args[0])
    let (targetCost, regexCost) = searchCosts(estimator, args)
    let resultSize = rangedSizeEstimate(0, targetSize.max)
    let allocationSize = resultSize.adding(.fixed(Cost.listCreateBaseCost))
    return callEstimate(targetCost.multiplied(by: regexCost).adding(costEstimate(allocationSize)), resultSize)
  }

  /// The search plus an output between no and every position replaced (cel-go
  /// `estimateReplaceCost`; the all-replaced size wraps as Go's does).
  @Sendable static func estimateReplace(
    _ estimator: any CostEstimator, _ target: CostAstNode?, _ args: [CostAstNode]
  ) -> CallEstimate? {
    guard target == nil, args.count == 3 || args.count == 4 else { return nil }
    let targetSize = estimateSize(estimator, args[0])
    let replacementSize = estimateSize(estimator, args[2])
    let (targetCost, regexCost) = searchCosts(estimator, args)
    let allReplacedSize = targetSize.max &* replacementSize.max
    let noneReplacedSize = targetSize.max
    var resultSize = rangedSizeEstimate(noneReplacedSize, allReplacedSize)
    if replacementSize.max == 0 {
      resultSize = rangedSizeEstimate(allReplacedSize, noneReplacedSize)
    }
    return callEstimate(targetCost.multiplied(by: regexCost).adding(resultSize.asCost), resultSize)
  }

  /// The call, the search and the result string, rounded up (cel-go `extractCostTracker`).
  @Sendable static func trackExtract(_ args: [Value], _ result: Value) -> UInt64? {
    let targetCost = Double(Cost.safeAdd(extActualSize(args[0]), 1)) * Cost.stringTraversalCostFactor
    let regexCost = Double(Cost.safeAdd(extActualSize(args[1]), 1)) * Cost.regexStringLengthCostFactor
    return goCeilUInt64(Double(callCost) + targetCost * regexCost + Double(extActualSize(result)))
  }

  /// The call, the search, the result list and its contents, rounded up (cel-go
  /// `extractAllCostTracker`; the sizes plus one wrap as Go's do).
  @Sendable static func trackExtractAll(_ args: [Value], _ result: Value) -> UInt64? {
    let targetCost = Double(extActualSize(args[0]) &+ 1) * Cost.stringTraversalCostFactor
    let regexCost = Double(extActualSize(args[1]) &+ 1) * Cost.regexStringLengthCostFactor
    let total =
      Double(callCost) + targetCost * regexCost + Double(extActualSize(result)) + Double(Cost.listCreateBaseCost)
    return goCeilUInt64(total)
  }

  /// The call, the search and the result string, truncated (cel-go `replaceCostTracker`).
  @Sendable static func trackReplace(_ args: [Value], _ result: Value) -> UInt64? {
    let targetCost = Double(extActualSize(args[0]) &+ 1) * Cost.stringTraversalCostFactor
    let regexCost = Double(extActualSize(args[1]) &+ 1) * Cost.regexStringLengthCostFactor
    return goUInt64(Double(callCost) + targetCost * regexCost + Double(extActualSize(result)))
  }
}

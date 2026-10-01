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
// Ported from cel-go ext/math.go: the cost estimators and trackers of `math.greatest` and
// `math.least` over a list (version 3 and later).

import CEL

enum MathCosts {
  static let listOverloads = [
    "math_@min_list_double", "math_@min_list_int", "math_@min_list_uint",
    "math_@max_list_double", "math_@max_list_int", "math_@max_list_uint",
  ]

  /// Estimators by overload id.
  static let estimators: [String: FunctionEstimator] = Dictionary(
    uniqueKeysWithValues: listOverloads.map { ($0, estimateList) })

  /// Trackers by overload id.
  static let trackers: [String: FunctionTracker] = Dictionary(
    uniqueKeysWithValues: listOverloads.map { ($0, trackList) })

  /// One per element plus the call (cel-go `estimateMathListCost`).
  @Sendable static func estimateList(
    _ estimator: any CostEstimator, _ target: CostAstNode?, _ args: [CostAstNode]
  ) -> CallEstimate? {
    guard args.count == 1 else { return nil }
    let size = estimateSize(estimator, args[0])
    return callEstimate(size.multipliedByCostFactor(1).adding(callCostEstimate), .fixed(1))
  }

  /// cel-go `trackMathListCost`.
  @Sendable static func trackList(_ args: [Value], _ result: Value) -> UInt64? {
    Cost.safeAdd(extActualSize(args[0]), callCost)
  }
}

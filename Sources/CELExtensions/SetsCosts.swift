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
// Ported from cel-go ext/sets.go: the cost estimators and trackers of the sets library.

import CEL

enum SetsCosts {
  /// Estimators by overload id; equivalence may need two m*n comparisons, one per direction.
  static let estimators: [String: FunctionEstimator] = [
    "list_sets_contains_list": estimate(costFactor: 1),
    "list_sets_intersects_list": estimate(costFactor: 1),
    "list_sets_equivalent_list": estimate(costFactor: 2),
  ]

  /// Trackers by overload id.
  static let trackers: [String: FunctionTracker] = [
    "list_sets_contains_list": track(costFactor: 1),
    "list_sets_intersects_list": track(costFactor: 1),
    "list_sets_equivalent_list": track(costFactor: 2),
  ]

  /// The product of the list sizes times the factor (cel-go `estimateSetsCost`).
  static func estimate(costFactor: Double) -> FunctionEstimator {
    { estimator, _, args in
      guard args.count == 2 else { return nil }
      let arg0Size = estimateSize(estimator, args[0])
      let arg1Size = estimateSize(estimator, args[1])
      let cost = arg0Size.multiplied(by: arg1Size).multipliedByCostFactor(costFactor).adding(callCostEstimate)
      return callEstimate(cost, nil)
    }
  }

  /// cel-go `trackSetsCost`; the product of the sizes wraps as Go's does.
  static func track(costFactor: Double) -> FunctionTracker {
    { args, _ in
      let lhsSize = extActualSize(args[0])
      let rhsSize = extActualSize(args[1])
      return Cost.safeAdd(callCost, goUInt64(Double(lhsSize &* rhsSize) * costFactor))
    }
  }
}

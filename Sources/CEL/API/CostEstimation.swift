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
// Re-designed from cel-go cel/env.go `EstimateCost` and the `CostEstimator` hook of
// checker/cost.go. cel-go takes an estimator object answering size and call-cost questions per
// AST node; the public surface here takes size ranges keyed by attribute path, which is what
// embedders bounding untrusted expressions supply in practice.

extension Environment {
  /// Estimates the minimum and maximum runtime cost of a checked expression (cel-go
  /// `Env.EstimateCost`).
  ///
  /// The estimate uses the same units as ``Program/Option/costLimit(_:)``, so a maximum below the
  /// limit guarantees the program never exceeds it. Without size hints, the sizes of strings,
  /// bytes, lists and maps that come from variables are unbounded and the maximum is
  /// `UInt64.max`.
  ///
  /// - Parameters:
  ///   - expression: An expression checked by this environment.
  ///   - sizeHints: Size ranges by attribute path: a variable name, then field names, and
  ///     `@items`, `@keys`, `@values` for the elements of lists and maps, joined with dots, such
  ///     as `pr.files` or `pr.files.@items.path`. A size is what CEL's `size()` returns.
  /// - Returns: The range of possible costs.
  public func estimateCost(
    _ expression: CheckedExpression, sizeHints: [String: ClosedRange<UInt64>] = [:]
  ) -> ClosedRange<UInt64> {
    let estimate = estimateCostDetails(expression, estimator: SizeHintEstimator(hints: sizeHints))
    return estimate.min...Swift.max(estimate.min, estimate.max)
  }
}

/// A cost estimator answering size questions from a table keyed by attribute path.
struct SizeHintEstimator: CostEstimator {
  let hints: [String: ClosedRange<UInt64>]

  func estimateSize(_ element: CostAstNode) -> SizeEstimate? {
    if element.path.isEmpty {
      return nil
    }
    guard let range = hints[element.path.joined(separator: ".")] else {
      return nil
    }
    return SizeEstimate(min: range.lowerBound, max: range.upperBound)
  }

  func estimateCallCost(
    function: String, overloadID: String, target: CostAstNode?, args: [CostAstNode]
  ) -> CallEstimate? {
    nil
  }
}

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
// Ported from cel-go common/cost.go and common/cost/cost.go: the cost constants and saturating
// arithmetic shared by the static estimator and runtime cost tracking.

/// Cost constants and saturating arithmetic (cel-go `common` cost constants and `common/cost`).
package enum Cost {
  /// The cost of accessing an identifier or performing a select.
  package static let selectAndIdentCost: UInt64 = 1
  /// The cost of accessing a constant.
  package static let constCost: UInt64 = 0
  /// The base cost of creating a list.
  package static let listCreateBaseCost: UInt64 = 10
  /// The base cost of creating a map.
  package static let mapCreateBaseCost: UInt64 = 30
  /// The base cost of creating a struct.
  package static let structCreateBaseCost: UInt64 = 40
  /// Multiplied by a string's length for the cost of traversing it once.
  package static let stringTraversalCostFactor = 0.1
  /// Multiplied by a regex pattern's length for the cost of applying it to a string of unit cost.
  package static let regexStringLengthCostFactor = 0.25

  /// `x + y + rest...`, saturating at `UInt64.max`.
  package static func safeAdd(_ x: UInt64, _ y: UInt64, _ rest: UInt64...) -> UInt64 {
    var (sum, overflow) = x.addingReportingOverflow(y)
    if overflow { return .max }
    for r in rest {
      (sum, overflow) = sum.addingReportingOverflow(r)
      if overflow { return .max }
    }
    return sum
  }

  /// `x * y`, saturating at `UInt64.max`.
  package static func safeMultiply(_ x: UInt64, _ y: UInt64) -> UInt64 {
    let (product, overflow) = x.multipliedReportingOverflow(by: y)
    return overflow ? .max : product
  }

  /// `ceil(x * factor)`, saturating at `UInt64.max`.
  package static func safeMultiplyByFactor(_ x: UInt64, _ factor: Double) -> UInt64 {
    let xFloat = Double(x)
    if xFloat > 0 && factor > 0 && xFloat > Double(UInt64.max) / factor {
      return .max
    }
    return safeCeil(xFloat * factor)
  }

  /// The smallest integer at least `x`, saturating at `UInt64.max` and flooring at zero; NaN is zero.
  package static func safeCeil(_ x: Double) -> UInt64 {
    if x.isNaN || x <= 0 {
      return 0
    }
    let ceil = x.rounded(.up)
    if ceil >= 18_446_744_073_709_551_616.0 {
      return .max
    }
    return UInt64(ceil)
  }
}

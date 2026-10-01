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
// Ported from cel-go ext/encoders.go: the cost estimators and trackers of `base64.encode`,
// `base64.decode` and `json.encode` (version 1 and later).

import CEL

enum EncodersCosts {
  /// Estimators by overload id.
  static let estimators: [String: FunctionEstimator] = [
    "base64_decode_string": estimateDecode,
    "base64_encode_bytes": estimateEncode,
    "json_encode_dyn": estimateJSONEncode,
  ]

  /// Trackers by overload id.
  static let trackers: [String: FunctionTracker] = [
    "base64_decode_string": trackDecode,
    "base64_encode_bytes": trackEncode,
    "json_encode_dyn": trackJSONEncode,
  ]

  /// A traversal of the input; the result is 4/3 of its size (cel-go `estimateEncode`).
  @Sendable static func estimateEncode(
    _ estimator: any CostEstimator, _ target: CostAstNode?, _ args: [CostAstNode]
  ) -> CallEstimate? {
    guard args.count == 1 else { return nil }
    let size = estimateSize(estimator, args[0])
    let cost = size.multipliedByCostFactor(stringCostFactor).adding(callCostEstimate)
    return callEstimate(cost, encodeSize(size))
  }

  /// The cost and result size of JSON encoding are unbounded (cel-go `estimateJSONEncode`).
  @Sendable static func estimateJSONEncode(
    _ estimator: any CostEstimator, _ target: CostAstNode?, _ args: [CostAstNode]
  ) -> CallEstimate? {
    guard args.count == 1 else { return nil }
    return callEstimate(.unknown, .unknown)
  }

  /// A traversal of the input; the result is 3/4 of its size (cel-go `estimateDecode`).
  @Sendable static func estimateDecode(
    _ estimator: any CostEstimator, _ target: CostAstNode?, _ args: [CostAstNode]
  ) -> CallEstimate? {
    guard args.count == 1 else { return nil }
    let size = estimateSize(estimator, args[0])
    let cost = size.multipliedByCostFactor(stringCostFactor).adding(callCostEstimate)
    return callEstimate(cost, decodeSize(size))
  }

  /// cel-go `trackEncode`.
  @Sendable static func trackEncode(_ args: [Value], _ result: Value) -> UInt64? {
    Cost.safeAdd(Cost.safeMultiplyByFactor(extActualSize(args[0]), stringCostFactor), callCost)
  }

  /// JSON encoding is charged the maximum cost (cel-go `trackJSONEncode`).
  @Sendable static func trackJSONEncode(_ args: [Value], _ result: Value) -> UInt64? {
    .max
  }

  /// cel-go `trackDecode`.
  @Sendable static func trackDecode(_ args: [Value], _ result: Value) -> UInt64? {
    Cost.safeAdd(Cost.safeMultiplyByFactor(extActualSize(args[0]), stringCostFactor), callCost)
  }

  /// The size of the base64 encoding (cel-go `estimateEncodeSize`; the minimum wraps as Go's
  /// does, the maximum saturates).
  static func encodeSize(_ size: SizeEstimate) -> SizeEstimate {
    let minVal = (size.min &* 4 &+ 2) / 3
    var maxVal = (size.max &* 4 &+ 2) / 3
    if size.max > UInt64.max / 4 {
      maxVal = .max
    }
    return SizeEstimate(min: minVal, max: maxVal)
  }

  /// The size of the decoded bytes (cel-go `estimateDecodeSize`; wraps as Go's does).
  static func decodeSize(_ size: SizeEstimate) -> SizeEstimate {
    SizeEstimate(min: size.min &* 3 / 4, max: size.max &* 3 / 4)
  }
}

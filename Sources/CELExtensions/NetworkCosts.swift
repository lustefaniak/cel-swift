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
// Ported from cel-go ext/network.go: the cost estimators and trackers of the network library, and
// the sizes of IP and CIDR values (cel-go `IP.Size`, `CIDR.Size`) that the runtime cost uses.

import CEL

extension IPAddressValue: CostSizedValue {
  /// The address size in bytes: 4 or 16 (cel-go `IP.Size`).
  var costSize: UInt64 { UInt64((addr.bitLen + 7) / 8) }
}

extension CIDRValue: CostSizedValue {
  /// The prefix length in bytes, rounded up (cel-go `CIDR.Size`).
  var costSize: UInt64 { UInt64((prefix.bits + 7) / 8) }
}

enum NetworkCosts {
  /// Estimators by overload id.
  static let estimators: [String: FunctionEstimator] = [
    "string_to_cidr": estimateParse,
    "cidr_to_string": estimateNominalString,
    "cidr_contains_cidr": estimateContainsCIDRCIDR,
    "cidr_contains_cidr_string": estimateContainsCIDRString,
    "cidr_contains_ip_ip": estimateContainsIPIP,
    "cidr_contains_ip_string": estimateContainsIPString,
    "ip_family": estimateNominal,
    "string_to_ip": estimateParse,
    "cidr_ip": estimateNominalOpaque,
    "ip_to_string": estimateNominalString,
    "ip_is_canonical": estimateIsCanonical,
    "is_cidr": estimateParseBool,
    "ip_is_global_unicast": estimateNominal,
    "is_ip": estimateParseBool,
    "ip_is_link_local_multicast": estimateNominal,
    "ip_is_link_local_unicast": estimateNominal,
    "ip_is_loopback": estimateNominal,
    "cidr_is_mask": estimateNominal,
    "ip_is_unspecified": estimateNominal,
    "cidr_masked": estimateNominalOpaque,
    "cidr_prefix_length": estimateNominal,
  ]

  /// Trackers by overload id.
  static let trackers: [String: FunctionTracker] = [
    "string_to_cidr": trackParse,
    "cidr_to_string": trackNominal,
    "cidr_contains_cidr": trackContainsCIDRCIDR,
    "cidr_contains_cidr_string": trackContainsCIDRString,
    "cidr_contains_ip_ip": trackContainsIPIP,
    "cidr_contains_ip_string": trackContainsIPString,
    "ip_family": trackNominal,
    "string_to_ip": trackParse,
    "cidr_ip": trackNominal,
    "ip_to_string": trackNominal,
    "ip_is_canonical": trackIsCanonical,
    "is_cidr": trackParse,
    "ip_is_global_unicast": trackNominal,
    "is_ip": trackParse,
    "ip_is_link_local_multicast": trackNominal,
    "ip_is_link_local_unicast": trackNominal,
    "ip_is_loopback": trackNominal,
    "cidr_is_mask": trackNominal,
    "ip_is_unspecified": trackNominal,
    "cidr_masked": trackNominal,
    "cidr_prefix_length": trackNominal,
  ]

  /// The size of an IP address or CIDR value in bytes.
  static let addressSize = rangedSizeEstimate(4, 16)

  /// Comparing two addresses.
  static let addressComparisonCost = addressSize.adding(addressSize).multipliedByCostFactor(stringCostFactor)

  /// cel-go `estimateNetworkParseCost`.
  @Sendable static func estimateParse(
    _ estimator: any CostEstimator, _ target: CostAstNode?, _ args: [CostAstNode]
  ) -> CallEstimate? {
    guard let arg = args.first else { return nil }
    return callEstimate(estimateSize(estimator, arg).multipliedByCostFactor(stringCostFactor), addressSize)
  }

  /// cel-go `estimateNetworkParseBoolCost`.
  @Sendable static func estimateParseBool(
    _ estimator: any CostEstimator, _ target: CostAstNode?, _ args: [CostAstNode]
  ) -> CallEstimate? {
    guard let arg = args.first else { return nil }
    return callEstimate(estimateSize(estimator, arg).multipliedByCostFactor(stringCostFactor), nil)
  }

  /// Parsing and formatting (cel-go `estimateIPIsCanonicalCost`).
  @Sendable static func estimateIsCanonical(
    _ estimator: any CostEstimator, _ target: CostAstNode?, _ args: [CostAstNode]
  ) -> CallEstimate? {
    guard let arg = args.first else { return nil }
    return callEstimate(estimateSize(estimator, arg).multipliedByCostFactor(2 * stringCostFactor), nil)
  }

  /// cel-go `estimateNetworkNominalCost`.
  @Sendable static func estimateNominal(
    _ estimator: any CostEstimator, _ target: CostAstNode?, _ args: [CostAstNode]
  ) -> CallEstimate? {
    callEstimate(callCostEstimate, nil)
  }

  /// cel-go `estimateNetworkNominalOpaqueCost`.
  @Sendable static func estimateNominalOpaque(
    _ estimator: any CostEstimator, _ target: CostAstNode?, _ args: [CostAstNode]
  ) -> CallEstimate? {
    callEstimate(callCostEstimate, addressSize)
  }

  /// The text of an address is 3 to 45 characters (cel-go `estimateNetworkNominalStringCost`).
  @Sendable static func estimateNominalString(
    _ estimator: any CostEstimator, _ target: CostAstNode?, _ args: [CostAstNode]
  ) -> CallEstimate? {
    callEstimate(callCostEstimate, rangedSizeEstimate(3, 45))
  }

  /// cel-go `estimateNetworkContainsIPIPCost`.
  @Sendable static func estimateContainsIPIP(
    _ estimator: any CostEstimator, _ target: CostAstNode?, _ args: [CostAstNode]
  ) -> CallEstimate? {
    callEstimate(addressComparisonCost, nil)
  }

  /// cel-go `estimateNetworkContainsIPStringCost`.
  @Sendable static func estimateContainsIPString(
    _ estimator: any CostEstimator, _ target: CostAstNode?, _ args: [CostAstNode]
  ) -> CallEstimate? {
    guard let arg = args.first else { return nil }
    let cost = addressComparisonCost.adding(estimateSize(estimator, arg).multipliedByCostFactor(stringCostFactor))
    return callEstimate(cost, nil)
  }

  /// cel-go `estimateNetworkContainsCIDRCIDRCost`; Kubernetes adds one for the extra traversal.
  @Sendable static func estimateContainsCIDRCIDR(
    _ estimator: any CostEstimator, _ target: CostAstNode?, _ args: [CostAstNode]
  ) -> CallEstimate? {
    let cost = addressComparisonCost.adding(addressSize.multipliedByCostFactor(stringCostFactor))
      .adding(callCostEstimate)
    return callEstimate(cost, nil)
  }

  /// cel-go `estimateNetworkContainsCIDRStringCost`.
  @Sendable static func estimateContainsCIDRString(
    _ estimator: any CostEstimator, _ target: CostAstNode?, _ args: [CostAstNode]
  ) -> CallEstimate? {
    guard let arg = args.first else { return nil }
    let cost = addressComparisonCost.adding(addressSize.multipliedByCostFactor(stringCostFactor))
      .adding(estimateSize(estimator, arg).multipliedByCostFactor(stringCostFactor))
      .adding(callCostEstimate)
    return callEstimate(cost, nil)
  }

  /// cel-go `trackNetworkParseCost`.
  @Sendable static func trackParse(_ args: [Value], _ result: Value) -> UInt64? {
    Cost.safeMultiplyByFactor(extActualSize(args[0]), stringCostFactor)
  }

  /// cel-go `trackIPIsCanonicalCost`.
  @Sendable static func trackIsCanonical(_ args: [Value], _ result: Value) -> UInt64? {
    Cost.safeMultiplyByFactor(extActualSize(args[0]), 2 * stringCostFactor)
  }

  /// cel-go `trackNetworkNominalCost`.
  @Sendable static func trackNominal(_ args: [Value], _ result: Value) -> UInt64? {
    callCost
  }

  /// cel-go `trackNetworkContainsIPIPCost`.
  @Sendable static func trackContainsIPIP(_ args: [Value], _ result: Value) -> UInt64? {
    let cidrSize = extActualSize(args[0])
    return Cost.safeMultiplyByFactor(Cost.safeAdd(cidrSize, cidrSize), stringCostFactor)
  }

  /// cel-go `trackNetworkContainsIPStringCost`.
  @Sendable static func trackContainsIPString(_ args: [Value], _ result: Value) -> UInt64? {
    let cidrSize = extActualSize(args[0])
    let otherSize = extActualSize(args[1])
    let total = Cost.safeMultiplyByFactor(Cost.safeAdd(cidrSize, cidrSize), stringCostFactor)
    return Cost.safeAdd(total, Cost.safeMultiplyByFactor(otherSize, stringCostFactor))
  }

  /// cel-go `trackNetworkContainsCIDRCIDRCost`.
  @Sendable static func trackContainsCIDRCIDR(_ args: [Value], _ result: Value) -> UInt64? {
    let cidrSize = extActualSize(args[0])
    let total = Cost.safeMultiplyByFactor(Cost.safeAdd(cidrSize, cidrSize), stringCostFactor)
    return Cost.safeAdd(total, Cost.safeMultiplyByFactor(cidrSize, stringCostFactor), 1)
  }

  /// cel-go `trackNetworkContainsCIDRStringCost`.
  @Sendable static func trackContainsCIDRString(_ args: [Value], _ result: Value) -> UInt64? {
    let cidrSize = extActualSize(args[0])
    let otherSize = extActualSize(args[1])
    var total = Cost.safeMultiplyByFactor(Cost.safeAdd(cidrSize, cidrSize), stringCostFactor)
    total = Cost.safeAdd(total, Cost.safeMultiplyByFactor(cidrSize, stringCostFactor), 1)
    return Cost.safeAdd(total, Cost.safeMultiplyByFactor(otherSize, stringCostFactor))
  }
}

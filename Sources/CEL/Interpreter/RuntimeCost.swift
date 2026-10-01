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
// Ported from cel-go interpreter/runtimecost.go. Any change to the cost formulas needs the same
// change in the static estimator (cel-go checker/cost.go).
//
// cel-go panics when the limit is exceeded; here the tracker marks the evaluation cancelled, stops
// accumulating, and the program reports the cancellation (comprehensions stop at the next
// iteration).

/// Provides the runtime cost of function calls (cel-go `ActualCostEstimator`).
package protocol ActualCostEstimator: Sendable {
  /// The cost of a call, or `nil` to use the default.
  func callCost(function: String, overloadID: String, args: [Value], result: Value) -> UInt64?
}

/// Computes the actual cost of a function call from its arguments and result (cel-go `FunctionTracker`).
package typealias FunctionTracker = @Sendable (_ args: [Value], _ result: Value) -> UInt64?

/// Configuration of a ``CostTracker``, copied into each evaluation's tracker.
package struct CostTrackerOptions: Sendable {
  package var estimator: (any ActualCostEstimator)?
  package var overloadTrackers: [String: FunctionTracker] = [:]
  package var limit: UInt64?
  /// Whether a presence test costs one (the default) or zero.
  package var presenceTestHasCost = true

  package init(estimator: (any ActualCostEstimator)? = nil, limit: UInt64? = nil) {
    self.estimator = estimator
    self.limit = limit
  }
}

/// Tracks the runtime cost of one evaluation (cel-go `CostTracker`).
package final class CostTracker {
  package let options: CostTrackerOptions
  package private(set) var cost: UInt64 = 0
  private var stack: [(value: Value, id: Int64)] = []

  package init(_ options: CostTrackerOptions = CostTrackerOptions()) {
    self.options = options
  }

  /// The runtime cost so far.
  package var actualCost: UInt64 { cost }

  /// Adds the incremental cost of a step (cel-go `costTrackerFactory.Observe`). Returns `false`
  /// when the limit is exceeded.
  func observe(_ id: Int64, _ step: Any, _ val: Value) -> Bool {
    switch step {
    case is any ConstantQualifier:
      cost &+= 1
    case is any InterpretableConst:
      break
    case let t as any InterpretableAttribute:
      if let cond = t.attr as? ConditionalAttribute {
        // A ternary has no direct cost; it comes from the condition and the branches.
        drop([cond.falsy.id, cond.truthy.id, cond.expr.id])
      } else {
        drop([t.attr.id])
        cost &+= Cost.selectAndIdentCost
      }
      if !options.presenceTestHasCost, t is EvalTestOnly {
        cost &-= Cost.selectAndIdentCost
      }
    case let t as EvalExhaustiveConditional:
      drop([t.attr.falsy.id, t.attr.truthy.id, t.attr.expr.id])
    case let t as EvalOr:
      drop(t.terms.map(\.id))
    case let t as EvalAnd:
      drop(t.terms.map(\.id))
    case let t as EvalExhaustiveOr:
      drop(t.terms.map(\.id))
    case let t as EvalExhaustiveAnd:
      drop(t.terms.map(\.id))
    case let t as EvalFold:
      drop([t.iterRange.id])
    case is any Qualifier:
      cost &+= 1
    case let t as any InterpretableCall:
      if let argVals = dropArgs(t.args) {
        // Wraps as cel-go's `tracker.cost += ...` does: a call charged `UInt64.max`, such as
        // `json.encode`, exceeds any limit at this step, and without a limit the total wraps.
        cost &+= costCall(t, argVals, val)
      }
    case let t as any InterpretableConstructor:
      _ = dropArgs(t.initVals)
      switch t.constructedType.kind {
      case .list: cost &+= Cost.listCreateBaseCost
      case .map: cost &+= Cost.mapCreateBaseCost
      default: cost &+= Cost.structCreateBaseCost
      }
    default:
      break
    }
    stack.append((val, id))
    if let limit = options.limit, cost > limit {
      return false
    }
    return true
  }

  func costCall(_ call: any InterpretableCall, _ args: [Value], _ result: Value) -> UInt64 {
    if let tracker = options.overloadTrackers[call.overloadID], let c = tracker(args, result) {
      return c
    }
    if let estimator = options.estimator,
      let c = estimator.callCost(function: call.function, overloadID: call.overloadID, args: args, result: result)
    {
      return c
    }
    let f = Cost.stringTraversalCostFactor
    switch call.overloadID {
    case Overloads.startsWithString, Overloads.endsWithString:
      return Cost.safeMultiplyByFactor(actualSize(args[1]), f)
    case Overloads.stringToBytes, Overloads.bytesToString, Overloads.extQuoteString, Overloads.extFormatString:
      return Cost.safeMultiplyByFactor(actualSize(args[0]), f)
    case Overloads.inList:
      return actualSize(args[1])
    case Overloads.lessString, Overloads.greaterString, Overloads.lessEqualsString, Overloads.greaterEqualsString,
      Overloads.lessBytes, Overloads.greaterBytes, Overloads.lessEqualsBytes, Overloads.greaterEqualsBytes,
      Overloads.equals, Overloads.notEquals:
      return Cost.safeMultiplyByFactor(min(actualSize(args[0]), actualSize(args[1])), f)
    case Overloads.addString, Overloads.addBytes:
      return Cost.safeMultiplyByFactor(Cost.safeAdd(actualSize(args[0]), actualSize(args[1])), f)
    case Overloads.matches, Overloads.matchesString:
      let strCost = Cost.safeMultiplyByFactor(Cost.safeAdd(1, actualSize(args[0])), f)
      let regexCost = Cost.safeMultiplyByFactor(actualSize(args[1]), Cost.regexStringLengthCostFactor)
      return Cost.safeMultiply(strCost, regexCost)
    case Overloads.containsString:
      let strCost = Cost.safeMultiplyByFactor(actualSize(args[0]), f)
      let substrCost = Cost.safeMultiplyByFactor(actualSize(args[1]), f)
      return Cost.safeMultiply(strCost, substrCost)
    default:
      return 1
    }
  }

  /// Removes each id and everything above it from the stack.
  private func drop(_ ids: [Int64]) {
    for id in ids {
      if let idx = stack.lastIndex(where: { $0.id == id }) {
        stack.removeSubrange(idx...)
      }
    }
  }

  /// Pops the values of the arguments, last argument highest on the stack; `nil` if one is missing.
  private func dropArgs(_ args: [any Interpretable]) -> [Value]? {
    var result = [Value](repeating: .null, count: args.count)
    for n in args.indices.reversed() {
      guard let idx = stack.lastIndex(where: { $0.id == args[n].id }) else {
        return nil
      }
      result[n] = stack[idx].value
      stack.removeSubrange(idx...)
    }
    return result
  }
}

/// An object value with a size for runtime cost purposes, as cel-go values implementing
/// `traits.Sizer` have, such as the network extension's IP addresses and CIDR prefixes. `size()`
/// does not apply to such values; only the cost tracker reads the size.
package protocol CostSizedValue: ObjectValue {
  /// The size the cost tracker uses for the value.
  var costSize: UInt64 { get }
}

/// The size of a value for cost purposes: string code points, bytes, list or map entries, the size
/// of a ``CostSizedValue``, the wrapped value of an optional, else 1 (cel-go `actualSize`).
func actualSize(_ value: Value) -> UInt64 {
  switch value {
  case .string, .bytes, .list, .map:
    if case .int(let n) = value.size() {
      return UInt64(clamping: n)
    }
    return 1
  case .object(let object):
    if let sized = object as? any CostSizedValue {
      return sized.costSize
    }
    return 1
  case .optional(let inner?):
    return actualSize(inner)
  default:
    return 1
  }
}

/// Tracks runtime cost with a fresh tracker per evaluation (cel-go `costTrackerFactory`).
package struct CostObserver: StatefulObserver {
  package let options: CostTrackerOptions

  package init(_ options: CostTrackerOptions) {
    self.options = options
  }

  package func initState(_ frame: ExecutionFrame) throws -> AnyObject {
    let ctx = frame.ensureContext()
    if let costs = ctx.costs {
      return costs
    }
    let tracker = CostTracker(options)
    ctx.costs = tracker
    return tracker
  }

  package func getState(_ frame: ExecutionFrame) -> AnyObject? {
    frame.context?.costs
  }

  package func observe(_ frame: ExecutionFrame, _ id: Int64, _ step: Any, _ value: Value) {
    guard let ctx = frame.context, let tracker = ctx.costs, ctx.cancellation == nil else {
      return
    }
    if !tracker.observe(id, step, value) {
      ctx.cancellation = .costLimitExceeded
    }
  }
}

/// The error message of an evaluation cancelled by the cost limit.
package let costLimitExceededMessage = "operation cancelled: actual cost limit exceeded"

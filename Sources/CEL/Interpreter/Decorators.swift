// Copyright 2018 Google LLC
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
// Ported from cel-go interpreter/decorators.go and interpreter/optimizations.go. Interpretables are
// immutable here, so decorators that set a flag on a fold return a copy.

import CELRegex

/// Wraps every node so its value is reported to the observer (cel-go `decObserveEval`).
func decObserveEval(_ observer: @escaping EvalObserver) -> InterpretableDecorator {
  { i in
    switch i {
    case is EvalWatch, is EvalWatchAttr, is EvalWatchConst, is EvalWatchConstructor:
      return i
    case let attr as any InterpretableAttribute:
      return EvalWatchAttr(attr, observer: observer)
    case let c as any InterpretableConst:
      return EvalWatchConst(c, observer: observer)
    case let c as any InterpretableConstructor:
      return EvalWatchConstructor(c, observer: observer)
    default:
      return EvalWatch(i, observer: observer)
    }
  }
}

/// Marks comprehensions as checking the interrupt every iteration (cel-go `decInterruptFolds`).
func decInterruptFolds() -> InterpretableDecorator {
  { i in
    guard let fold = i as? EvalFold else {
      return i
    }
    return fold.with(interruptable: true)
  }
}

/// Replaces short-circuiting operators with exhaustive ones (cel-go `decDisableShortcircuits`).
func decDisableShortcircuits() -> InterpretableDecorator {
  { i in
    switch i {
    case let or as EvalOr:
      return EvalExhaustiveOr(id: or.id, terms: or.terms)
    case let and as EvalAnd:
      return EvalExhaustiveAnd(id: and.id, terms: and.terms)
    case let fold as EvalFold:
      return fold.with(exhaustive: true)
    case let attr as any InterpretableAttribute:
      if let cond = attr.attr as? ConditionalAttribute {
        return EvalExhaustiveConditional(id: cond.condID, attr: cond)
      }
      return i
    default:
      return i
    }
  }
}

/// Precomputes constant list and map literals, constant type conversions, and `in` tests against
/// constant lists (cel-go `decOptimize`).
func decOptimize() -> InterpretableDecorator {
  { i in
    switch i {
    case let list as EvalList:
      return maybeBuildListLiteral(i, list)
    case let map as EvalMap:
      return maybeBuildMapLiteral(i, map)
    case let call as any InterpretableCall:
      if call.overloadID == Overloads.inList {
        return maybeOptimizeSetMembership(i, call)
      }
      if Overloads.isTypeConversionFunction(call.function) {
        return try maybeOptimizeConstUnary(i, call)
      }
      return i
    default:
      return i
    }
  }
}

private func maybeOptimizeConstUnary(_ i: any Interpretable, _ call: any InterpretableCall) throws
  -> any Interpretable
{
  let args = call.args
  guard args.count == 1, args[0] is any InterpretableConst else {
    return i
  }
  let val = call.evaluate(EmptyActivation())
  if case .error(let err) = val {
    throw PlanError(err.message)
  }
  return EvalConst(id: call.id, value: val)
}

private func maybeBuildListLiteral(_ i: any Interpretable, _ l: EvalList) -> any Interpretable {
  for elem in l.elems where !(elem is any InterpretableConst) {
    return i
  }
  return EvalConst(id: l.id, value: l.evaluate(EmptyActivation()))
}

private func maybeBuildMapLiteral(_ i: any Interpretable, _ m: EvalMap) -> any Interpretable {
  for (k, v) in zip(m.keys, m.vals) where !(k is any InterpretableConst) || !(v is any InterpretableConst) {
    return i
  }
  return EvalConst(id: m.id, value: m.evaluate(EmptyActivation()))
}

/// `x in [c1, c2, ...]` with constant primitive elements as a set lookup. Numbers are added under
/// every lossless numeric conversion so heterogeneous equality still holds.
private func maybeOptimizeSetMembership(_ i: any Interpretable, _ inlist: any InterpretableCall)
  -> any Interpretable
{
  let args = inlist.args
  guard args.count == 2, let l = args[1] as? any InterpretableConst, case .list(let list) = l.value else {
    return i
  }
  if list.count == 0 {
    return EvalConst(id: inlist.id, value: .bool(false))
  }
  var valueSet = Set<PrimitiveKey>()
  func insert(_ v: Value) {
    if !v.isError, let key = PrimitiveKey(v) {
      valueSet.insert(key)
    }
  }
  for idx in 0..<list.count {
    let elem = list.element(at: idx)
    // Non-primitives are not supported, and bytes are not hashable in cel-go's set.
    guard elem.isPrimitive, !isBytes(elem) else {
      return i
    }
    insert(elem)
    switch elem {
    case .double:
      // Only lossless conversions join the set.
      for t in [CELType.int, .uint] {
        let v = elem.convert(to: t)
        if case .bool(true) = v.celEquals(elem) {
          insert(v)
        }
      }
    case .int:
      insert(elem.convert(to: .double))
      insert(elem.convert(to: .uint))
    case .uint:
      insert(elem.convert(to: .double))
      insert(elem.convert(to: .int))
    default:
      break
    }
  }
  return EvalSetMembership(inst: inlist, arg: args[0], valueSet: valueSet)
}

private func isBytes(_ v: Value) -> Bool {
  if case .bytes = v { return true }
  return false
}

/// Compiles constant `matches` patterns once at plan time, reporting invalid patterns as plan errors
/// (cel-go `decRegexOptimizer` with `MatchesRegexOptimization`).
func decRegexOptimizer() -> InterpretableDecorator {
  { i in
    guard let call = i as? any InterpretableCall, call.function == Overloads.matches else {
      return i
    }
    let args = call.args
    guard args.count == 2, let c = args[1] as? any InterpretableConst, case .string(let pattern) = c.value
    else {
      return i
    }
    let regex: Regexp
    do {
      regex = try Regexp(pattern)
    } catch {
      throw PlanError("\(error)")
    }
    return EvalVarArgs(
      id: call.id, function: call.function, overloadID: call.overloadID, args: args, trait: [],
      impl: { values in
        guard values.count == 2, case .string(let s) = values[0] else {
          return .noSuchOverload
        }
        return .bool(regex.matchString(s))
      }, nonStrict: false)
  }
}

// Copyright (c) 2012-2022 The ANTLR Project. All rights reserved.
// Use of this file is governed by the BSD 3-clause license that
// can be found in the LICENSE.txt file in the project root.

// Ported from antlr4-go v4.13.1 prediction_context.go.

/// A graph-structured stack of rule return states used during adaptive prediction.
final class PredictionContext: Hashable, Sendable {
  enum Kind: Sendable {
    case empty
    case singleton
    case array
  }

  static let emptyReturnState = 0x7FFF_FFFF

  let kind: Kind
  let cachedHash: Int
  /// Singleton: the parent context (may be nil in LL(1) analysis without a context).
  let parentContext: PredictionContext?
  /// Singleton: the return state.
  let singletonReturnState: Int
  /// Array: parents, parallel to `returnStates`.
  let parents: [PredictionContext?]
  /// Array: sorted return states.
  let returnStates: [Int]

  private static let emptyHash: Int = MurmurHash.finish(MurmurHash.initialize(1), 0)

  /// The empty context `$`.
  static let empty = PredictionContext(
    kind: .empty, hash: emptyHash, parent: nil, returnState: emptyReturnState, parents: [],
    returnStates: [])

  private init(
    kind: Kind, hash: Int, parent: PredictionContext?, returnState: Int,
    parents: [PredictionContext?], returnStates: [Int]
  ) {
    self.kind = kind
    self.cachedHash = hash
    self.parentContext = parent
    self.singletonReturnState = returnState
    self.parents = parents
    self.returnStates = returnStates
  }

  /// antlr `SingletonBasePredictionContextCreate`.
  static func singleton(parent: PredictionContext?, returnState: Int) -> PredictionContext {
    if returnState == emptyReturnState && parent == nil {
      return empty
    }
    let hash: Int
    if let parent {
      var h = MurmurHash.initialize(1)
      h = MurmurHash.update(h, parent.cachedHash)
      h = MurmurHash.update(h, returnState)
      hash = MurmurHash.finish(h, 2)
    } else {
      hash = emptyHash
    }
    return PredictionContext(
      kind: .singleton, hash: hash, parent: parent, returnState: returnState, parents: [],
      returnStates: [])
  }

  /// antlr `NewArrayPredictionContext`.
  static func array(parents: [PredictionContext?], returnStates: [Int]) -> PredictionContext {
    var h = MurmurHash.initialize(1)
    for parent in parents {
      h = MurmurHash.update(h, parent?.cachedHash ?? 0)
    }
    for rs in returnStates {
      h = MurmurHash.update(h, rs)
    }
    h = MurmurHash.finish(h, parents.count << 1)
    return PredictionContext(
      kind: .array, hash: h, parent: nil, returnState: 0, parents: parents,
      returnStates: returnStates)
  }

  func parent(_ i: Int) -> PredictionContext? {
    switch kind {
    case .empty: return nil
    case .singleton: return parentContext
    case .array: return parents[i]
    }
  }

  func returnState(_ i: Int) -> Int {
    switch kind {
    case .array: return returnStates[i]
    default: return singletonReturnState
    }
  }

  var allReturnStates: [Int] {
    kind == .array ? returnStates : [singletonReturnState]
  }

  var length: Int {
    kind == .array ? returnStates.count : 1
  }

  var hasEmptyPath: Bool {
    if kind == .singleton {
      return singletonReturnState == PredictionContext.emptyReturnState
    }
    return returnState(length - 1) == PredictionContext.emptyReturnState
  }

  var isEmpty: Bool {
    switch kind {
    case .empty: return true
    case .array: return !returnStates.isEmpty && returnStates[0] == PredictionContext.emptyReturnState
    case .singleton: return false
    }
  }

  /// antlr `PredictionContext.Equals`, including its asymmetry for the empty context.
  func equals(_ other: PredictionContext?) -> Bool {
    if let other, self === other {
      return true
    }
    switch kind {
    case .empty:
      guard let other else { return true }
      return other.isEmpty
    case .singleton:
      guard let other, other.kind == .singleton, cachedHash == other.cachedHash,
        singletonReturnState == other.returnState(0)
      else {
        return false
      }
      return PredictionContext.equals(parentContext, other.parentContext)
    case .array:
      guard let other, other.kind == .array, cachedHash == other.cachedHash else {
        return false
      }
      guard returnStates == other.returnStates, parents.count == other.parents.count else {
        return false
      }
      for i in parents.indices where !PredictionContext.equals(parents[i], other.parents[i]) {
        return false
      }
      return true
    }
  }

  /// Equality of optional contexts: two nils are equal, a nil and a non-nil are not.
  static func equals(_ a: PredictionContext?, _ b: PredictionContext?) -> Bool {
    guard let a else {
      return b == nil
    }
    if b == nil {
      return a.kind == .empty
    }
    return a.equals(b)
  }

  static func == (lhs: PredictionContext, rhs: PredictionContext) -> Bool {
    lhs.equals(rhs)
  }

  func hash(into hasher: inout Hasher) {
    hasher.combine(cachedHash)
  }

  /// Converts a parser rule invocation stack into a prediction context.
  static func from(_ atn: ATN, _ outerContext: ParserRuleContext?) -> PredictionContext {
    guard let outerContext, outerContext.parent != nil else {
      return empty
    }
    var chain: [ParserRuleContext] = []
    var c: ParserRuleContext? = outerContext
    while let ctx = c, ctx.parent != nil {
      chain.append(ctx)
      c = ctx.parent
    }
    var result = empty
    for ctx in chain.reversed() {
      let state = atn.states[ctx.invokingState]
      let transition = state.transitions[0]
      result = singleton(parent: result, returnState: transition.followState)
    }
    return result
  }
}

/// Key for the merge cache: an ordered pair of contexts compared by value.
struct PredictionContextPair: Hashable {
  let a: PredictionContext
  let b: PredictionContext

  static func == (lhs: PredictionContextPair, rhs: PredictionContextPair) -> Bool {
    lhs.a.equals(rhs.a) && lhs.b.equals(rhs.b)
  }

  func hash(into hasher: inout Hasher) {
    hasher.combine(a.cachedHash)
    hasher.combine(b.cachedHash)
  }
}

/// The merge cache of one prediction, shared by reference.
final class MergeCache {
  var map: [PredictionContextPair: PredictionContext] = [:]
}

extension PredictionContext {
  /// antlr `merge`.
  static func merge(
    _ a: PredictionContext, _ b: PredictionContext, rootIsWildcard: Bool, _ mergeCache: MergeCache?
  ) -> PredictionContext {
    if a === b || a.equals(b) {
      return a
    }
    if a.kind == .singleton && b.kind == .singleton {
      return mergeSingletons(a, b, rootIsWildcard, mergeCache)
    }
    if rootIsWildcard {
      if a.isEmpty {
        return a
      }
      if b.isEmpty {
        return b
      }
    }
    let ara = convertToArray(a)
    let arb = convertToArray(b)
    return mergeArrays(ara, arb, rootIsWildcard, mergeCache)
  }

  private static func convertToArray(_ pc: PredictionContext) -> PredictionContext {
    switch pc.kind {
    case .empty:
      return array(parents: [], returnStates: [])
    case .singleton:
      return array(parents: [pc.parent(0)], returnStates: [pc.returnState(0)])
    case .array:
      return pc
    }
  }

  private static func cacheGet(
    _ cache: MergeCache?, _ a: PredictionContext, _ b: PredictionContext
  ) -> PredictionContext? {
    guard let cache else { return nil }
    if let previous = cache.map[PredictionContextPair(a: a, b: b)] {
      return previous
    }
    return cache.map[PredictionContextPair(a: b, b: a)]
  }

  private static func cachePut(
    _ cache: MergeCache?, _ a: PredictionContext, _ b: PredictionContext,
    _ value: PredictionContext
  ) {
    cache?.map[PredictionContextPair(a: a, b: b)] = value
  }

  private static func mergeSingletons(
    _ a: PredictionContext, _ b: PredictionContext, _ rootIsWildcard: Bool,
    _ mergeCache: MergeCache?
  ) -> PredictionContext {
    if let previous = cacheGet(mergeCache, a, b) {
      return previous
    }
    if let rootMerge = mergeRoot(a, b, rootIsWildcard) {
      cachePut(mergeCache, a, b, rootMerge)
      return rootMerge
    }
    if a.singletonReturnState == b.singletonReturnState {
      let parent = mergeOptional(a.parentContext, b.parentContext, rootIsWildcard, mergeCache)
      if PredictionContext.equals(parent, a.parentContext) {
        return a
      }
      if PredictionContext.equals(parent, b.parentContext) {
        return b
      }
      let spc = singleton(parent: parent, returnState: a.singletonReturnState)
      cachePut(mergeCache, a, b, spc)
      return spc
    }
    var singleParent: PredictionContext? = nil
    var haveSingleParent = false
    if a.equals(b) {
      singleParent = a.parentContext
      haveSingleParent = singleParent != nil
    } else if let ap = a.parentContext, ap.equals(b.parentContext) {
      singleParent = ap
      haveSingleParent = true
    }
    if haveSingleParent, let singleParent {
      var payloads = [a.singletonReturnState, b.singletonReturnState]
      if a.singletonReturnState > b.singletonReturnState {
        payloads = [b.singletonReturnState, a.singletonReturnState]
      }
      let apc = array(parents: [singleParent, singleParent], returnStates: payloads)
      cachePut(mergeCache, a, b, apc)
      return apc
    }
    var payloads = [a.singletonReturnState, b.singletonReturnState]
    var parents = [a.parentContext, b.parentContext]
    if a.singletonReturnState > b.singletonReturnState {
      payloads = [b.singletonReturnState, a.singletonReturnState]
      parents = [b.parentContext, a.parentContext]
    }
    let apc = array(parents: parents, returnStates: payloads)
    cachePut(mergeCache, a, b, apc)
    return apc
  }

  /// Merges possibly-nil parents; nil only occurs for contexts built without a rule context.
  private static func mergeOptional(
    _ a: PredictionContext?, _ b: PredictionContext?, _ rootIsWildcard: Bool,
    _ mergeCache: MergeCache?
  ) -> PredictionContext? {
    guard let a, let b else {
      return a ?? b
    }
    return merge(a, b, rootIsWildcard: rootIsWildcard, mergeCache)
  }

  private static func mergeRoot(
    _ a: PredictionContext, _ b: PredictionContext, _ rootIsWildcard: Bool
  ) -> PredictionContext? {
    if rootIsWildcard {
      if a.kind == .empty {
        return empty
      }
      if b.kind == .empty {
        return empty
      }
    } else {
      if a.isEmpty && b.isEmpty {
        return empty
      } else if a.isEmpty {
        return array(parents: [b.parent(-1), nil], returnStates: [b.returnState(-1), emptyReturnState])
      } else if b.isEmpty {
        return array(parents: [a.parent(-1), nil], returnStates: [a.returnState(-1), emptyReturnState])
      }
    }
    return nil
  }

  private static func mergeArrays(
    _ a: PredictionContext, _ b: PredictionContext, _ rootIsWildcard: Bool,
    _ mergeCache: MergeCache?
  ) -> PredictionContext {
    if let previous = cacheGet(mergeCache, a, b) {
      return previous
    }
    var i = 0
    var j = 0
    var mergedReturnStates: [Int] = []
    var mergedParents: [PredictionContext?] = []
    mergedReturnStates.reserveCapacity(a.returnStates.count + b.returnStates.count)
    mergedParents.reserveCapacity(a.returnStates.count + b.returnStates.count)
    while i < a.returnStates.count && j < b.returnStates.count {
      let aParent = a.parents[i]
      let bParent = b.parents[j]
      if a.returnStates[i] == b.returnStates[j] {
        let payload = a.returnStates[i]
        let bothDollars = payload == emptyReturnState && aParent == nil && bParent == nil
        let axAX = aParent != nil && bParent != nil && PredictionContext.equals(aParent, bParent)
        if bothDollars || axAX {
          mergedParents.append(aParent)
          mergedReturnStates.append(payload)
        } else {
          mergedParents.append(mergeOptional(aParent, bParent, rootIsWildcard, mergeCache))
          mergedReturnStates.append(payload)
        }
        i += 1
        j += 1
      } else if a.returnStates[i] < b.returnStates[j] {
        mergedParents.append(aParent)
        mergedReturnStates.append(a.returnStates[i])
        i += 1
      } else {
        mergedParents.append(bParent)
        mergedReturnStates.append(b.returnStates[j])
        j += 1
      }
    }
    if i < a.returnStates.count {
      for p in i..<a.returnStates.count {
        mergedParents.append(a.parents[p])
        mergedReturnStates.append(a.returnStates[p])
      }
    } else {
      for p in j..<b.returnStates.count {
        mergedParents.append(b.parents[p])
        mergedReturnStates.append(b.returnStates[p])
      }
    }
    let total = a.returnStates.count + b.returnStates.count
    if mergedParents.count < total && mergedParents.count == 1 {
      let pc = singleton(parent: mergedParents[0], returnState: mergedReturnStates[0])
      cachePut(mergeCache, a, b, pc)
      return pc
    }
    let m = array(parents: mergedParents, returnStates: mergedReturnStates)
    if m.equals(a) {
      cachePut(mergeCache, a, b, a)
      return a
    }
    if m.equals(b) {
      cachePut(mergeCache, a, b, b)
      return b
    }
    cachePut(mergeCache, a, b, m)
    return m
  }
}

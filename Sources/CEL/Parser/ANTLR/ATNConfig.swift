// Copyright (c) 2012-2022 The ANTLR Project. All rights reserved.
// Use of this file is governed by the BSD 3-clause license that
// can be found in the LICENSE.txt file in the project root.

// Ported from antlr4-go v4.13.1 atn_config.go, atn_config_set.go, semantic_context.go, dfa.go,
// dfa_state.go and prediction_mode.go (parser parts only).

/// A semantic predicate context. The CEL grammar only has precedence predicates.
indirect enum SemanticContext: Hashable {
  case none
  case predicate(ruleIndex: Int, predIndex: Int, isCtxDependent: Bool)
  case precedence(Int)
  case and([SemanticContext])
  case or([SemanticContext])

  var hashValueForANTLR: Int {
    switch self {
    case .none:
      return SemanticContext.predicate(ruleIndex: -1, predIndex: -1, isCtxDependent: false)
        .hashValueForANTLR
    case .predicate(let r, let p, let dep):
      var h = MurmurHash.initialize(0)
      h = MurmurHash.update(h, r)
      h = MurmurHash.update(h, p)
      h = MurmurHash.update(h, dep ? 1 : 0)
      return MurmurHash.finish(h, 3)
    case .precedence(let p):
      return Int(UInt32(truncatingIfNeeded: 31 &+ p))
    case .and(let ops):
      var h = MurmurHash.initialize(37)
      for op in ops { h = MurmurHash.update(h, op.hashValueForANTLR) }
      return MurmurHash.finish(h, ops.count)
    case .or(let ops):
      var h = MurmurHash.initialize(41)
      for op in ops { h = MurmurHash.update(h, op.hashValueForANTLR) }
      return MurmurHash.finish(h, ops.count)
    }
  }

  func evaluate(_ parser: ParserRuntime, _ outerContext: ParserRuleContext?) -> Bool {
    switch self {
    case .none:
      return true
    case .predicate(let ruleIndex, let predIndex, let isCtxDependent):
      return parser.sempred(isCtxDependent ? outerContext : nil, ruleIndex, predIndex)
    case .precedence(let p):
      return parser.precpred(p)
    case .and(let ops):
      return ops.allSatisfy { $0.evaluate(parser, outerContext) }
    case .or(let ops):
      return ops.contains { $0.evaluate(parser, outerContext) }
    }
  }

  /// Simplifies precedence predicates against the current precedence; `nil` means "false".
  func evalPrecedence(_ parser: ParserRuntime, _ outerContext: ParserRuleContext?) -> SemanticContext? {
    switch self {
    case .none, .predicate:
      return self
    case .precedence(let p):
      return parser.precpred(p) ? SemanticContext.none : nil
    case .and(let ops):
      var differs = false
      var operands: [SemanticContext] = []
      for context in ops {
        let evaluated = context.evalPrecedence(parser, outerContext)
        differs = differs || evaluated != context
        guard let evaluated else { return nil }
        if evaluated != .none {
          operands.append(evaluated)
        }
      }
      if !differs { return self }
      if operands.isEmpty { return SemanticContext.none }
      var result = operands[0]
      for o in operands.dropFirst() { result = SemanticContext.andContext(result, o) }
      return result
    case .or(let ops):
      var differs = false
      var operands: [SemanticContext] = []
      for context in ops {
        let evaluated = context.evalPrecedence(parser, outerContext)
        differs = differs || evaluated != context
        if evaluated == SemanticContext.none {
          return SemanticContext.none
        } else if let evaluated {
          operands.append(evaluated)
        }
      }
      if !differs { return self }
      if operands.isEmpty { return nil }
      var result = operands[0]
      for o in operands.dropFirst() { result = SemanticContext.orContext(result, o) }
      return result
    }
  }

  static func andContext(_ a: SemanticContext?, _ b: SemanticContext?) -> SemanticContext {
    guard let a, a != .none else { return b ?? .none }
    guard let b, b != .none else { return a }
    var operands: [SemanticContext] = []
    func put(_ x: SemanticContext) { if !operands.contains(x) { operands.append(x) } }
    if case .and(let aa) = a { aa.forEach(put) } else { put(a) }
    if case .and(let ba) = b { ba.forEach(put) } else { put(b) }
    var reduced: Int? = nil
    for case .precedence(let p) in operands where reduced == nil || p < reduced! {
      reduced = p
    }
    if let reduced { put(.precedence(reduced)) }
    if operands.count == 1 { return operands[0] }
    return .and(operands)
  }

  static func orContext(_ a: SemanticContext?, _ b: SemanticContext?) -> SemanticContext {
    guard let a else { return b ?? .none }
    guard let b else { return a }
    if a == .none || b == .none { return .none }
    var operands: [SemanticContext] = []
    func put(_ x: SemanticContext) { if !operands.contains(x) { operands.append(x) } }
    if case .or(let aa) = a { aa.forEach(put) } else { put(a) }
    if case .or(let ba) = b { ba.forEach(put) } else { put(b) }
    var reduced: Int? = nil
    for case .precedence(let p) in operands where reduced == nil || p > reduced! {
      reduced = p
    }
    if let reduced { put(.precedence(reduced)) }
    if operands.count == 1 { return operands[0] }
    return .or(operands)
  }
}

/// A (state, alternative, context, predicate) tuple of the ATN simulation.
final class ATNConfig {
  var precedenceFilterSuppressed = false
  let state: Int
  let alt: Int
  var context: PredictionContext?
  let semanticContext: SemanticContext
  var reachesIntoOuterContext = 0

  init(state: Int, alt: Int, context: PredictionContext?, semanticContext: SemanticContext = .none) {
    self.state = state
    self.alt = alt
    self.context = context
    self.semanticContext = semanticContext
  }

  /// Copies `c` with a new state, context and/or semantic context (antlr `NewATNConfig*`).
  init(
    _ c: ATNConfig, state: Int? = nil, context: PredictionContext?? = nil,
    semanticContext: SemanticContext? = nil
  ) {
    self.state = state ?? c.state
    self.alt = c.alt
    switch context {
    case .some(let ctx): self.context = ctx
    case .none: self.context = c.context
    }
    self.semanticContext = semanticContext ?? c.semanticContext
    self.reachesIntoOuterContext = c.reachesIntoOuterContext
    self.precedenceFilterSuppressed = c.precedenceFilterSuppressed
  }

  /// antlr `ATNConfig.PEquals`.
  func equals(_ other: ATNConfig) -> Bool {
    if self === other { return true }
    let contextsEqual: Bool
    if let context {
      contextsEqual = context.equals(other.context)
    } else {
      contextsEqual = other.context == nil
    }
    return state == other.state && alt == other.alt && semanticContext == other.semanticContext
      && precedenceFilterSuppressed == other.precedenceFilterSuppressed && contextsEqual
  }

  /// antlr `ATNConfig.PHash`.
  var antlrHash: Int {
    var h = MurmurHash.initialize(7)
    h = MurmurHash.update(h, state)
    h = MurmurHash.update(h, alt)
    h = MurmurHash.update(h, context?.cachedHash ?? 0)
    h = MurmurHash.update(h, semanticContext.hashValueForANTLR)
    return MurmurHash.finish(h, 4)
  }
}

/// Set key comparing configs with `ATNConfig.equals`, hashed at insertion like antlr's `JStore`.
struct ConfigEqualityKey: Hashable {
  let config: ATNConfig
  let hash: Int

  init(_ config: ATNConfig) {
    self.config = config
    self.hash = config.antlrHash
  }

  static func == (lhs: ConfigEqualityKey, rhs: ConfigEqualityKey) -> Bool {
    lhs.config.equals(rhs.config)
  }

  func hash(into hasher: inout Hasher) {
    hasher.combine(hash)
  }
}

/// Key for `ATNConfigSet` lookup: state, alternative and semantic context.
private struct ConfigLookupKey: Hashable {
  let state: Int
  let alt: Int
  let semanticContext: SemanticContext
}

/// An ordered set of configurations (antlr `ATNConfigSet`).
final class ATNConfigSet {
  private var configLookup: [ConfigLookupKey: ATNConfig] = [:]
  private(set) var configs: [ATNConfig] = []
  var conflictingAlts: BitSet? = nil
  var dipsIntoOuterContext = false
  let fullCtx: Bool
  var hasSemanticContext = false
  var readOnly = false
  var uniqueAlt = 0

  init(fullCtx: Bool) {
    self.fullCtx = fullCtx
  }

  @discardableResult
  func add(_ config: ATNConfig, _ mergeCache: inout MergeCache?) -> Bool {
    precondition(!readOnly, "set is read-only")
    if config.semanticContext != .none {
      hasSemanticContext = true
    }
    if config.reachesIntoOuterContext > 0 {
      dipsIntoOuterContext = true
    }
    let key = ConfigLookupKey(
      state: config.state, alt: config.alt, semanticContext: config.semanticContext)
    guard let existing = configLookup[key] else {
      configLookup[key] = config
      configs.append(config)
      return true
    }
    let rootIsWildcard = !fullCtx
    let merged: PredictionContext?
    if let ec = existing.context, let cc = config.context {
      merged = PredictionContext.merge(ec, cc, rootIsWildcard: rootIsWildcard, &mergeCache)
    } else {
      merged = existing.context ?? config.context
    }
    existing.reachesIntoOuterContext = max(
      existing.reachesIntoOuterContext, config.reachesIntoOuterContext)
    if config.precedenceFilterSuppressed {
      existing.precedenceFilterSuppressed = true
    }
    existing.context = merged
    return true
  }

  func add(_ config: ATNConfig) {
    var noCache: MergeCache? = nil
    add(config, &noCache)
  }

  var alts: BitSet {
    var alts = BitSet()
    for c in configs {
      alts.add(c.alt)
    }
    return alts
  }

  var isEmpty: Bool { configs.isEmpty }

  /// antlr `ATNConfigSet.Equals`.
  func equals(_ other: ATNConfigSet) -> Bool {
    if self === other { return true }
    guard fullCtx == other.fullCtx, uniqueAlt == other.uniqueAlt,
      conflictingAlts == other.conflictingAlts, hasSemanticContext == other.hasSemanticContext,
      dipsIntoOuterContext == other.dipsIntoOuterContext, configs.count == other.configs.count
    else {
      return false
    }
    for i in configs.indices where !configs[i].equals(other.configs[i]) {
      return false
    }
    return true
  }

  var antlrHash: Int {
    var h = 1
    for c in configs {
      h = 31 &* h &+ c.antlrHash
    }
    return h
  }
}

/// A predicate that selects an alternative (antlr `PredPrediction`).
struct PredPrediction {
  let pred: SemanticContext
  let alt: Int
}

/// A DFA state caching prediction results (antlr `DFAState`).
final class DFAState {
  var stateNumber: Int
  var configs: ATNConfigSet
  var edges: [DFAState?]? = nil
  var isAcceptState = false
  var prediction = 0
  var requiresFullContext = false
  var predicates: [PredPrediction]? = nil

  init(stateNumber: Int, configs: ATNConfigSet) {
    self.stateNumber = stateNumber
    self.configs = configs
  }
}

private struct DFAStateKey: Hashable {
  let state: DFAState
  let hash: Int

  init(_ state: DFAState) {
    self.state = state
    var h = MurmurHash.initialize(7)
    h = MurmurHash.update(h, state.configs.antlrHash)
    self.hash = MurmurHash.finish(h, 1)
  }

  static func == (lhs: DFAStateKey, rhs: DFAStateKey) -> Bool {
    lhs.state === rhs.state || lhs.state.configs.equals(rhs.state.configs)
  }

  func hash(into hasher: inout Hasher) {
    hasher.combine(hash)
  }
}

/// The prediction DFA of one decision (antlr `DFA`). Caches are per parse.
final class DFA {
  let atnStartState: Int
  let decision: Int
  private var states: [DFAStateKey: DFAState] = [:]
  var s0: DFAState? = nil
  let precedenceDfa: Bool

  init(atn: ATN, decision: Int) {
    let startState = atn.decisionToState[decision]
    self.atnStartState = startState
    self.decision = decision
    let s = atn.states[startState]
    if s.type == .starLoopEntry && s.precedenceRuleDecision {
      precedenceDfa = true
      let s0 = DFAState(stateNumber: -1, configs: ATNConfigSet(fullCtx: false))
      s0.edges = []
      self.s0 = s0
    } else {
      precedenceDfa = false
    }
  }

  var count: Int { states.count }

  func get(_ s: DFAState) -> DFAState? {
    states[DFAStateKey(s)]
  }

  func put(_ s: DFAState) {
    states[DFAStateKey(s)] = s
  }

  func precedenceStartState(_ precedence: Int) -> DFAState? {
    guard let edges = s0?.edges, precedence >= 0, precedence < edges.count else {
      return nil
    }
    return edges[precedence]
  }

  func setPrecedenceStartState(_ precedence: Int, _ startState: DFAState) {
    guard precedence >= 0, let s0 else {
      return
    }
    var edges = s0.edges ?? []
    if precedence >= edges.count {
      edges.append(contentsOf: Array(repeating: nil, count: precedence + 1 - edges.count))
    }
    edges[precedence] = startState
    s0.edges = edges
  }
}

// MARK: - Prediction mode helpers

enum PredictionMode {
  static func allConfigsInRuleStopStates(_ configs: ATNConfigSet, _ atn: ATN) -> Bool {
    configs.configs.allSatisfy { atn.states[$0.state].type == .ruleStop }
  }

  static func hasConfigInRuleStopState(_ configs: ATNConfigSet, _ atn: ATN) -> Bool {
    configs.configs.contains { atn.states[$0.state].type == .ruleStop }
  }

  /// Groups configs by (state, context) and returns the alternatives of each group.
  static func conflictingAltSubsets(_ configs: ATNConfigSet) -> [BitSet] {
    struct Key: Hashable {
      let state: Int
      let context: PredictionContext?
      static func == (lhs: Key, rhs: Key) -> Bool {
        lhs.state == rhs.state && PredictionContext.equals(lhs.context, rhs.context)
      }
      func hash(into hasher: inout Hasher) {
        hasher.combine(state)
        hasher.combine(context?.cachedHash ?? 0)
      }
    }
    var order: [Key] = []
    var map: [Key: BitSet] = [:]
    for c in configs.configs {
      let key = Key(state: c.state, context: c.context)
      if map[key] == nil {
        order.append(key)
        map[key] = BitSet()
      }
      map[key]?.add(c.alt)
    }
    return order.compactMap { map[$0] }
  }

  static func hasConflictingAltSet(_ altsets: [BitSet]) -> Bool {
    altsets.contains { $0.length > 1 }
  }

  static func hasNonConflictingAltSet(_ altsets: [BitSet]) -> Bool {
    altsets.contains { $0.length == 1 }
  }

  static func hasStateAssociatedWithOneAlt(_ configs: ATNConfigSet) -> Bool {
    var m: [Int: BitSet] = [:]
    for c in configs.configs {
      m[c.state, default: BitSet()].add(c.alt)
    }
    return m.values.contains { $0.length == 1 }
  }

  static func alts(_ altsets: [BitSet]) -> BitSet {
    var all = BitSet()
    for a in altsets {
      all.or(a)
    }
    return all
  }

  static func singleViableAlt(_ altsets: [BitSet]) -> Int {
    var result = 0
    for alts in altsets {
      let minAlt = alts.minValue
      if result == 0 {
        result = minAlt
      } else if result != minAlt {
        return 0
      }
    }
    return result
  }

  /// SLL conflict detection with LL fallback (antlr `PredictionModehasSLLConflictTerminatingPrediction`
  /// for prediction mode LL).
  static func hasSLLConflictTerminatingPrediction(_ configs: ATNConfigSet, _ atn: ATN) -> Bool {
    if allConfigsInRuleStopStates(configs, atn) {
      return true
    }
    let altsets = conflictingAltSubsets(configs)
    return hasConflictingAltSet(altsets) && !hasStateAssociatedWithOneAlt(configs)
  }
}

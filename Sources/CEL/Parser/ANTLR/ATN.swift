// Copyright (c) 2012-2022 The ANTLR Project. All rights reserved.
// Use of this file is governed by the BSD 3-clause license that
// can be found in the LICENSE.txt file in the project root.

// Ported from antlr4-go v4.13.1 atn.go, atn_state.go, transition.go, atn_deserializer.go and
// ll1_analyzer.go.
//
// The ATN is immutable after deserialization and stored as value types; states and transitions refer
// to each other by state number.

enum ATNStateType: Int {
  case invalid = 0
  case basic = 1
  case ruleStart = 2
  case blockStart = 3
  case plusBlockStart = 4
  case starBlockStart = 5
  case tokenStart = 6
  case ruleStop = 7
  case blockEnd = 8
  case starLoopBack = 9
  case starLoopEntry = 10
  case plusLoopBack = 11
  case loopEnd = 12
}

struct Transition: Sendable {
  enum Kind: Int, Sendable {
    case epsilon = 1
    case range = 2
    case rule = 3
    case predicate = 4
    case atom = 5
    case action = 6
    case set = 7
    case notSet = 8
    case wildcard = 9
    case precedence = 10
  }

  var kind: Kind
  var target: Int
  /// Atom label, range start, rule index, predicate rule index, action rule index or precedence.
  var arg1 = 0
  /// Range stop, rule precedence, predicate index or action index.
  var arg2 = 0
  /// Rule transitions: the follow state number.
  var followState = -1
  /// Epsilon transitions: the outermost precedence return rule index, or -1.
  var outermostPrecedenceReturn = -1
  var isCtxDependent = false
  var set: IntervalSet? = nil

  var isEpsilon: Bool {
    switch kind {
    case .epsilon, .rule, .predicate, .action, .precedence: return true
    default: return false
    }
  }

  /// The label set of a token-consuming transition (antlr `getLabel`).
  var label: IntervalSet? {
    switch kind {
    case .atom: return IntervalSet(arg1)
    case .range:
      var s = IntervalSet()
      s.addRange(arg1, arg2)
      return s
    case .set, .notSet: return set
    default: return nil
    }
  }

  func matches(_ symbol: Int, _ minVocabSymbol: Int, _ maxVocabSymbol: Int) -> Bool {
    switch kind {
    case .atom: return arg1 == symbol
    case .range: return symbol >= arg1 && symbol <= arg2
    case .set: return set?.contains(symbol) ?? false
    case .notSet:
      return symbol >= minVocabSymbol && symbol <= maxVocabSymbol && !(set?.contains(symbol) ?? false)
    case .wildcard: return symbol >= minVocabSymbol && symbol <= maxVocabSymbol
    default: return false
    }
  }
}

struct ATNState: Sendable {
  var stateNumber: Int
  var type: ATNStateType
  var ruleIndex: Int
  var transitions: [Transition] = []
  var epsilonOnlyTransitions = false
  /// Block start states: the matching block end.
  var endState = -1
  /// Block end states: the matching block start.
  var startState = -1
  /// Loop end, plus block start and star loop entry states: the loop back state.
  var loopBackState = -1
  /// Rule start states: the rule stop state.
  var stopState = -1
  var isPrecedenceRule = false
  var precedenceRuleDecision = false
  var nonGreedy = false
  var decision = -1

  var isBlockStart: Bool {
    type == .blockStart || type == .plusBlockStart || type == .starBlockStart
  }

  var isDecisionState: Bool {
    isBlockStart || type == .plusLoopBack || type == .starLoopEntry || type == .tokenStart
  }

  mutating func addTransition(_ t: Transition) {
    if transitions.isEmpty {
      epsilonOnlyTransitions = t.isEpsilon
    } else if epsilonOnlyTransitions != t.isEpsilon {
      epsilonOnlyTransitions = false
    }
    transitions.append(t)
  }
}

struct ATN: Sendable {
  var grammarType = 0
  var maxTokenType = 0
  var states: [ATNState] = []
  var decisionToState: [Int] = []
  var ruleToStartState: [Int] = []
  var ruleToStopState: [Int] = []
  /// Next tokens within the rule for every state (antlr caches these lazily as `NextTokenWithinRule`).
  var nextTokensWithinRule: [IntervalSet] = []

  init(serialized data: [Int]) {
    var d = ATNDeserializer(data: data)
    self = d.deserialize()
    var next: [IntervalSet] = []
    next.reserveCapacity(states.count)
    for s in states.indices {
      next.append(LL1Analyzer(atn: self).look(s, stopState: nil, ctx: nil))
    }
    nextTokensWithinRule = next
  }

  fileprivate init() {}

  /// Tokens that can follow `state` within its rule; contains epsilon when the rule end is reachable.
  func nextTokens(_ state: Int) -> IntervalSet {
    nextTokensWithinRule[state]
  }

  /// Tokens that can follow `state` given the rule invocation stack `ctx`.
  func nextTokens(_ state: Int, ctx: PredictionContext?) -> IntervalSet {
    LL1Analyzer(atn: self).look(state, stopState: nil, ctx: ctx)
  }
}

// MARK: - Deserializer

private struct ATNDeserializer {
  let data: [Int]
  var pos = 0

  init(data: [Int]) {
    self.data = data
  }

  mutating func readInt() -> Int {
    let v = data[pos]
    pos += 1
    return v
  }

  mutating func deserialize() -> ATN {
    let version = readInt()
    precondition(version == 4, "Could not deserialize ATN with version \(version)")
    var atn = ATN()
    atn.grammarType = readInt()
    atn.maxTokenType = readInt()
    readStates(&atn)
    readRules(&atn)
    readModes(&atn)
    let sets = readSets()
    readEdges(&atn, sets)
    readDecisions(&atn)
    markPrecedenceDecisions(&atn)
    return atn
  }

  mutating func readStates(_ atn: inout ATN) {
    let nstates = readInt()
    var loopBackStateNumbers: [(Int, Int)] = []
    var endStateNumbers: [(Int, Int)] = []
    for i in 0..<nstates {
      let stype = readInt()
      if stype == ATNStateType.invalid.rawValue {
        atn.states.append(ATNState(stateNumber: i, type: .invalid, ruleIndex: -1))
        continue
      }
      let ruleIndex = readInt()
      guard let type = ATNStateType(rawValue: stype) else {
        preconditionFailure("state type \(stype) is invalid")
      }
      let s = ATNState(stateNumber: i, type: type, ruleIndex: ruleIndex)
      if type == .loopEnd {
        loopBackStateNumbers.append((i, readInt()))
      } else if s.isBlockStart {
        endStateNumbers.append((i, readInt()))
      }
      atn.states.append(s)
    }
    for (s, loopBack) in loopBackStateNumbers {
      atn.states[s].loopBackState = loopBack
    }
    for (s, end) in endStateNumbers {
      atn.states[s].endState = end
    }
    let numNonGreedyStates = readInt()
    for _ in 0..<numNonGreedyStates {
      atn.states[readInt()].nonGreedy = true
    }
    let numPrecedenceStates = readInt()
    for _ in 0..<numPrecedenceStates {
      atn.states[readInt()].isPrecedenceRule = true
    }
  }

  mutating func readRules(_ atn: inout ATN) {
    let nrules = readInt()
    for _ in 0..<nrules {
      let s = readInt()
      atn.ruleToStartState.append(s)
      if atn.grammarType == 0 {
        _ = readInt()  // lexer token type
      }
    }
    atn.ruleToStopState = Array(repeating: -1, count: nrules)
    for state in atn.states where state.type == .ruleStop {
      atn.ruleToStopState[state.ruleIndex] = state.stateNumber
      atn.states[atn.ruleToStartState[state.ruleIndex]].stopState = state.stateNumber
    }
  }

  mutating func readModes(_ atn: inout ATN) {
    let nmodes = readInt()
    for _ in 0..<nmodes {
      _ = readInt()
    }
  }

  mutating func readSets() -> [IntervalSet] {
    var sets: [IntervalSet] = []
    let m = readInt()
    for _ in 0..<m {
      var iset = IntervalSet()
      let n = readInt()
      let containsEOF = readInt()
      if containsEOF != 0 {
        iset.addOne(-1)
      }
      for _ in 0..<n {
        let i1 = readInt()
        let i2 = readInt()
        iset.addRange(i1, i2)
      }
      sets.append(iset)
    }
    return sets
  }

  mutating func readEdges(_ atn: inout ATN, _ sets: [IntervalSet]) {
    let nedges = readInt()
    for _ in 0..<nedges {
      let src = readInt()
      let trg = readInt()
      let ttype = readInt()
      let arg1 = readInt()
      let arg2 = readInt()
      let arg3 = readInt()
      let trans = edgeFactory(ttype, trg, arg1, arg2, arg3, sets)
      atn.states[src].addTransition(trans)
    }
    // Edges for rule stop states can be derived, so they are not serialized.
    for state in atn.states {
      for t in state.transitions where t.kind == .rule {
        var outermostPrecedenceReturn = -1
        let targetRule = atn.states[t.target].ruleIndex
        if atn.states[atn.ruleToStartState[targetRule]].isPrecedenceRule {
          if t.arg2 == 0 {
            outermostPrecedenceReturn = targetRule
          }
        }
        var trans = Transition(kind: .epsilon, target: t.followState)
        trans.outermostPrecedenceReturn = outermostPrecedenceReturn
        atn.states[atn.ruleToStopState[targetRule]].addTransition(trans)
      }
    }
    for i in atn.states.indices {
      let state = atn.states[i]
      if state.isBlockStart {
        atn.states[state.endState].startState = i
      }
      if state.type == .plusLoopBack {
        for t in state.transitions where atn.states[t.target].type == .plusBlockStart {
          atn.states[t.target].loopBackState = i
        }
      } else if state.type == .starLoopBack {
        for t in state.transitions where atn.states[t.target].type == .starLoopEntry {
          atn.states[t.target].loopBackState = i
        }
      }
    }
  }

  mutating func readDecisions(_ atn: inout ATN) {
    let ndecisions = readInt()
    for i in 0..<ndecisions {
      let s = readInt()
      atn.decisionToState.append(s)
      atn.states[s].decision = i
    }
  }

  func markPrecedenceDecisions(_ atn: inout ATN) {
    for i in atn.states.indices {
      let state = atn.states[i]
      guard state.type == .starLoopEntry,
        atn.states[atn.ruleToStartState[state.ruleIndex]].isPrecedenceRule,
        let last = state.transitions.last
      else {
        continue
      }
      let maybeLoopEnd = atn.states[last.target]
      if maybeLoopEnd.type == .loopEnd, maybeLoopEnd.epsilonOnlyTransitions,
        let first = maybeLoopEnd.transitions.first, atn.states[first.target].type == .ruleStop
      {
        atn.states[i].precedenceRuleDecision = true
      }
    }
  }

  func edgeFactory(
    _ type: Int, _ trg: Int, _ arg1: Int, _ arg2: Int, _ arg3: Int, _ sets: [IntervalSet]
  ) -> Transition {
    guard let kind = Transition.Kind(rawValue: type) else {
      preconditionFailure("The specified transition type is not valid.")
    }
    switch kind {
    case .epsilon:
      return Transition(kind: .epsilon, target: trg)
    case .range:
      return Transition(kind: .range, target: trg, arg1: arg3 != 0 ? TokenType.eof : arg1, arg2: arg2)
    case .rule:
      // target = rule start (arg1), follow state = trg
      return Transition(kind: .rule, target: arg1, arg1: arg2, arg2: arg3, followState: trg)
    case .predicate:
      return Transition(
        kind: .predicate, target: trg, arg1: arg1, arg2: arg2, isCtxDependent: arg3 != 0)
    case .precedence:
      return Transition(kind: .precedence, target: trg, arg1: arg1)
    case .atom:
      return Transition(kind: .atom, target: trg, arg1: arg3 != 0 ? TokenType.eof : arg1)
    case .action:
      return Transition(kind: .action, target: trg, arg1: arg1, arg2: arg2, isCtxDependent: arg3 != 0)
    case .set:
      return Transition(kind: .set, target: trg, set: sets[arg1])
    case .notSet:
      return Transition(kind: .notSet, target: trg, set: sets[arg1])
    case .wildcard:
      return Transition(kind: .wildcard, target: trg)
    }
  }
}

// MARK: - LL(1) analysis

private struct LookBusyKey: Hashable {
  let state: Int
  let ctx: PredictionContext?
  let hash: Int

  init(state: Int, ctx: PredictionContext?) {
    self.state = state
    self.ctx = ctx
    var h = MurmurHash.initialize(7)
    h = MurmurHash.update(h, state)
    h = MurmurHash.update(h, 0)
    h = MurmurHash.update(h, ctx?.cachedHash ?? 0)
    h = MurmurHash.update(h, SemanticContext.none.hashValueForANTLR)
    hash = MurmurHash.finish(h, 4)
  }

  static func == (lhs: LookBusyKey, rhs: LookBusyKey) -> Bool {
    guard lhs.state == rhs.state else { return false }
    return PredictionContext.equals(lhs.ctx, rhs.ctx)
  }

  func hash(into hasher: inout Hasher) {
    hasher.combine(hash)
  }
}

struct LL1Analyzer {
  let atn: ATN

  /// The tokens that can follow `s`, optionally with the rule invocation stack `ctx`.
  func look(_ s: Int, stopState: Int?, ctx: PredictionContext?) -> IntervalSet {
    var r = IntervalSet()
    var lookBusy = Set<LookBusyKey>()
    var calledRuleStack = Set<Int>()
    look1(s, stopState, ctx, &r, &lookBusy, &calledRuleStack, seeThruPreds: true, addEOF: true)
    return r
  }

  private func look1(
    _ s: Int, _ stopState: Int?, _ ctx: PredictionContext?, _ look: inout IntervalSet,
    _ lookBusy: inout Set<LookBusyKey>, _ calledRuleStack: inout Set<Int>, seeThruPreds: Bool,
    addEOF: Bool
  ) {
    let key = LookBusyKey(state: s, ctx: ctx)
    if lookBusy.contains(key) {
      return
    }
    lookBusy.insert(key)
    if s == stopState {
      if ctx == nil {
        look.addOne(TokenType.epsilon)
        return
      } else if let ctx, ctx.isEmpty && addEOF {
        look.addOne(TokenType.eof)
        return
      }
    }
    let state = atn.states[s]
    if state.type == .ruleStop {
      guard let ctx else {
        look.addOne(TokenType.epsilon)
        return
      }
      if ctx.isEmpty && addEOF {
        look.addOne(TokenType.eof)
        return
      }
      if ctx.kind != .empty {
        let removed = calledRuleStack.contains(state.ruleIndex)
        calledRuleStack.remove(state.ruleIndex)
        for i in 0..<ctx.length {
          let returnState = ctx.returnState(i)
          look1(
            returnState, stopState, ctx.parent(i), &look, &lookBusy, &calledRuleStack,
            seeThruPreds: seeThruPreds, addEOF: addEOF)
        }
        if removed {
          calledRuleStack.insert(state.ruleIndex)
        }
        return
      }
    }
    for t in state.transitions {
      switch t.kind {
      case .rule:
        let targetRule = atn.states[t.target].ruleIndex
        if calledRuleStack.contains(targetRule) {
          continue
        }
        let newContext = PredictionContext.singleton(parent: ctx, returnState: t.followState)
        calledRuleStack.insert(targetRule)
        look1(
          t.target, stopState, newContext, &look, &lookBusy, &calledRuleStack,
          seeThruPreds: seeThruPreds, addEOF: addEOF)
        calledRuleStack.remove(targetRule)
      case .predicate, .precedence:
        if seeThruPreds {
          look1(
            t.target, stopState, ctx, &look, &lookBusy, &calledRuleStack, seeThruPreds: seeThruPreds,
            addEOF: addEOF)
        } else {
          look.addOne(TokenType.invalid)
        }
      case .wildcard:
        look.addRange(TokenType.minUserTokenType, atn.maxTokenType)
      default:
        if t.isEpsilon {
          look1(
            t.target, stopState, ctx, &look, &lookBusy, &calledRuleStack, seeThruPreds: seeThruPreds,
            addEOF: addEOF)
        } else if var set = t.label {
          if t.kind == .notSet {
            set = set.complement(TokenType.minUserTokenType, atn.maxTokenType)
          }
          look.addSet(set)
        }
      }
    }
  }
}

/// Murmur hash helpers matching antlr's `murmurInit` / `murmurUpdate` / `murmurFinish`.
enum MurmurHash {
  static func initialize(_ seed: Int) -> Int {
    seed
  }

  static func update(_ h: Int, _ value: Int) -> Int {
    let c1: UInt32 = 0xCC9E_2D51
    let c2: UInt32 = 0x1B87_3593
    var k = UInt32(truncatingIfNeeded: value)
    k = k &* c1
    k = (k << 15) | (k >> 17)
    k = k &* c2
    var hash = UInt32(truncatingIfNeeded: h) ^ k
    hash = (hash << 13) | (hash >> 19)
    hash = hash &* 5 &+ 0xE654_6B64
    return Int(hash)
  }

  static func finish(_ h: Int, _ numberOfWords: Int) -> Int {
    var hash = UInt32(truncatingIfNeeded: h)
    hash ^= UInt32(truncatingIfNeeded: numberOfWords) << 2
    hash ^= hash >> 16
    hash = hash &* 0x85EB_CA6B
    hash ^= hash >> 13
    hash = hash &* 0xC2B2_AE35
    hash ^= hash >> 16
    return Int(hash)
  }
}

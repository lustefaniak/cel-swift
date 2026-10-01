// Copyright (c) 2012-2022 The ANTLR Project. All rights reserved.
// Use of this file is governed by the BSD 3-clause license that
// can be found in the LICENSE.txt file in the project root.

// Ported from antlr4-go v4.13.1 parser.go, common_token_stream.go, error_strategy.go and errors.go,
// together with the error listener, recursion listener and recovery limits of cel-go
// parser/parser.go (Copyright 2018 Google LLC, Apache-2.0).

/// Reasons a parse is abandoned; cel-go implements these as panics recovered in `parser.parse`.
enum ParseAbort: Error {
  /// Reported as an internal error (`expression recursion limit exceeded`, `max recursion depth exceeded`).
  case recursion(String)
  /// Reported as an internal error (`error recovery token lookahead limit exceeded`).
  case lookahead(String)
  /// The error reporting limit was reached; the report was already recorded.
  case tooManyErrors
  /// The error recovery attempt limit was reached; the report was already recorded.
  case recoveryLimit
}

/// The parsed ATN of cel-go's generated CEL parser.
let celParserATN = ATN(serialized: celParserSerializedATN)

/// Per-parse state of the ANTLR runtime: token stream, parser, error strategy and prediction.
final class ParserRuntime {
  let atn: ATN

  // MARK: Token stream (antlr CommonTokenStream, default channel only)

  private var lexer: CELLexer
  private(set) var tokens: [Token] = []
  private(set) var tokenIndex = -1
  private var fetchedEOF = false

  // MARK: Parser state (antlr BaseParser)

  var state = -1
  var ctx: ParserRuleContext?
  private var precedenceStack: [Int] = [0]
  /// The pending recognition error (antlr `HasError` / `GetError`).
  var error: RecognitionException?

  // MARK: Error strategy (antlr DefaultErrorStrategy + cel-go recoveryLimitErrorStrategy)

  private var errorRecoveryMode = false
  private var lastErrorIndex = -1
  private var lastErrorStates: IntervalSet?
  private var recoveryAttempts = 0
  private let errorRecoveryLimit: Int
  private let lookaheadLimit: Int
  private var lookaheadAttempts = 0

  // MARK: Listeners (cel-go recursionListener and the parser as error listener)

  private var ruleDepth = [Int](repeating: 0, count: CELRule.count)
  private let maxRecursionDepth: Int
  private var errorReports = 0
  private let errorReportingLimit: Int
  private let sourceInfo: SourceInfo
  var errors: CELErrors

  // MARK: Prediction (antlr ParserATNSimulator)

  /// The prediction DFAs, shared with other parses; see `PredictionCache` for what its locks guard.
  private let cache: PredictionCache
  private let errorState: DFAState
  private var mergeCache: MergeCache?
  private var startIndex = 0
  private var outerContext: ParserRuleContext?
  private var currentDFA: DFA?

  init(
    input: [Unicode.Scalar], sourceInfo: SourceInfo, errors: CELErrors, maxRecursionDepth: Int,
    errorReportingLimit: Int, errorRecoveryLimit: Int, lookaheadLimit: Int, cache: PredictionCache
  ) {
    self.atn = celParserATN
    self.cache = cache
    self.errorState = cache.errorState
    self.lexer = CELLexer(input: input)
    self.sourceInfo = sourceInfo
    self.errors = errors
    self.maxRecursionDepth = maxRecursionDepth
    self.errorReportingLimit = errorReportingLimit
    self.errorRecoveryLimit = errorRecoveryLimit
    self.lookaheadLimit = lookaheadLimit
  }

  // MARK: - Token stream

  private func lazyInit() throws {
    if tokenIndex == -1 {
      _ = try sync(0)
      tokenIndex = try nextTokenOnChannel(0)
    }
  }

  private func sync(_ i: Int) throws -> Bool {
    let n = i - tokens.count + 1
    if n > 0 {
      let fetched = try fetch(n)
      return fetched >= n
    }
    return true
  }

  private func fetch(_ n: Int) throws -> Int {
    if fetchedEOF {
      return 0
    }
    for i in 0..<n {
      let t = try nextLexerToken()
      t.tokenIndex = tokens.count
      tokens.append(t)
      if t.type == TokenType.eof {
        fetchedEOF = true
        return i + 1
      }
    }
    return n
  }

  private func nextLexerToken() throws -> Token {
    while true {
      switch lexer.nextStep() {
      case .token(let t):
        return t
      case .error(let line, let column, let text):
        try syntaxError(line: line, column: column, "token recognition error at: '\(text)'")
      }
    }
  }

  private func nextTokenOnChannel(_ start: Int) throws -> Int {
    var i = start
    _ = try sync(i)
    if i >= tokens.count {
      return -1
    }
    var token = tokens[i]
    while token.channel != CELToken.defaultChannel {
      if token.type == TokenType.eof {
        return -1
      }
      i += 1
      _ = try sync(i)
      token = tokens[i]
    }
    return i
  }

  private func previousTokenOnChannel(_ start: Int) -> Int {
    var i = start
    while i >= 0 && tokens[i].channel != CELToken.defaultChannel {
      i -= 1
    }
    return i
  }

  /// antlr `LT`: the k-th on-channel token ahead (k > 0) or behind (k < 0).
  func lt(_ k: Int) throws -> Token? {
    try lazyInit()
    if k == 0 {
      return nil
    }
    if k < 0 {
      return lb(-k)
    }
    var i = tokenIndex
    var n = 1
    while n < k {
      if try sync(i + 1) {
        i = try nextTokenOnChannel(i + 1)
      }
      n += 1
    }
    return tokens[i]
  }

  private func lb(_ k: Int) -> Token? {
    if k == 0 || tokenIndex - k < 0 {
      return nil
    }
    var i = tokenIndex
    var n = 1
    while n <= k {
      i = previousTokenOnChannel(i - 1)
      n += 1
    }
    if i < 0 {
      return nil
    }
    return tokens[i]
  }

  /// antlr `LA`: the type of the k-th token ahead.
  func la(_ k: Int) throws -> Int {
    try lt(k)?.type ?? TokenType.invalid
  }

  private func consumeToken() throws {
    var skipEOFCheck = false
    if tokenIndex >= 0 {
      if fetchedEOF {
        skipEOFCheck = tokenIndex < tokens.count - 1
      } else {
        skipEOFCheck = tokenIndex < tokens.count
      }
    }
    if !skipEOFCheck, try la(1) == TokenType.eof {
      preconditionFailure("cannot consume EOF")
    }
    if try sync(tokenIndex + 1) {
      tokenIndex = try nextTokenOnChannel(tokenIndex + 1)
    }
  }

  private func seek(_ index: Int) throws {
    try lazyInit()
    tokenIndex = try nextTokenOnChannel(index)
  }

  /// The text of the tokens in `[start, stop]`, including hidden tokens, stopping at EOF.
  private func text(from start: Int, to stopIndex: Int) throws -> String {
    try lazyInit()
    _ = try sync(stopIndex)
    if start < 0 || stopIndex < 0 {
      return ""
    }
    let stop = min(stopIndex, tokens.count - 1)
    var s = ""
    var i = start
    while i <= stop {
      let t = tokens[i]
      if t.type == TokenType.eof {
        break
      }
      s += t.text
      i += 1
    }
    return s
  }

  // MARK: - Parser (antlr BaseParser)

  func currentToken() throws -> Token {
    guard let t = try lt(1) else {
      preconditionFailure("no current token")
    }
    return t
  }

  /// antlr `Match`.
  func match(_ ttype: Int) throws -> Token? {
    var t = try currentToken()
    if t.type == ttype {
      reportMatch()
      try consume()
    } else {
      let recovered = try recoverInline()
      if error != nil {
        return nil
      }
      guard let recovered else {
        return nil
      }
      t = recovered
      if t.tokenIndex == -1 {
        ctx?.children.append(.error(t))
      }
    }
    return t
  }

  /// antlr `Consume`: moves past the current token and adds it to the parse tree.
  @discardableResult
  func consume() throws -> Token {
    let o = try currentToken()
    if o.type != TokenType.eof {
      try consumeToken()
    }
    if errorRecoveryMode {
      ctx?.children.append(.error(o))
    } else {
      ctx?.children.append(.terminal(o))
    }
    return o
  }

  func enterRule(_ localctx: ParserRuleContext, _ state: Int) throws {
    self.state = state
    ctx = localctx
    localctx.start = try lt(1)
    localctx.parent?.addChild(localctx)
    try triggerEnterRule()
  }

  func exitRule() throws {
    guard let current = ctx else {
      return
    }
    current.stop = try lt(-1)
    triggerExitRule()
    state = current.invokingState
    ctx = current.parent
  }

  func enterOuterAlt(_ localctx: ParserRuleContext) {
    if let current = ctx, current !== localctx, let parent = current.parent {
      parent.removeLastChild()
      parent.addChild(localctx)
    }
    ctx = localctx
  }

  var precedence: Int {
    precedenceStack.last ?? -1
  }

  func enterRecursionRule(_ localctx: ParserRuleContext, _ state: Int, _ precedence: Int) throws {
    self.state = state
    precedenceStack.append(precedence)
    ctx = localctx
    localctx.start = try lt(1)
    try triggerEnterRule()
  }

  func pushNewRecursionContext(_ localctx: ParserRuleContext, _ state: Int) throws {
    guard let previous = ctx else {
      return
    }
    previous.parent = localctx
    previous.invokingState = state
    previous.stop = try lt(-1)
    ctx = localctx
    localctx.start = previous.start
    localctx.addChild(previous)
    try triggerEnterRule()
  }

  func unrollRecursionContexts(_ parentCtx: ParserRuleContext?) throws {
    precedenceStack.removeLast()
    guard let retCtx = ctx else {
      return
    }
    retCtx.stop = try lt(-1)
    while let current = ctx, current !== parentCtx {
      triggerExitRule()
      ctx = current.parent
    }
    retCtx.parent = parentCtx
    parentCtx?.addChild(retCtx)
  }

  /// antlr `Precpred`.
  func precpred(_ precedence: Int) -> Bool {
    precedence >= (precedenceStack.last ?? 0)
  }

  /// cel-go `CELParser.Sempred`: the grammar's predicates are all precedence predicates.
  func sempred(_ localctx: ParserRuleContext?, _ ruleIndex: Int, _ predIndex: Int) -> Bool {
    switch (ruleIndex, predIndex) {
    case (4, 0): return precpred(1)
    case (5, 1): return precpred(2)
    case (5, 2): return precpred(1)
    case (7, 3): return precpred(3)
    case (7, 4): return precpred(2)
    case (7, 5): return precpred(1)
    default: preconditionFailure("No predicate with index: \(predIndex)")
    }
  }

  private func triggerEnterRule() throws {
    guard let ctx else {
      return
    }
    let r = ctx.ruleIndex
    ruleDepth[r] += 1
    if ruleDepth[r] > maxRecursionDepth {
      throw ParseAbort.recursion("expression recursion limit exceeded: \(maxRecursionDepth)")
    }
  }

  func triggerExitRule() {
    guard let ctx else {
      return
    }
    let r = ctx.ruleIndex
    if ruleDepth[r] > 0 {
      ruleDepth[r] -= 1
    }
  }

  func expectedTokens() -> IntervalSet {
    expectedTokens(state, ctx)
  }

  /// antlr `ATN.getExpectedTokens`.
  func expectedTokens(_ stateNumber: Int, _ context: ParserRuleContext?) -> IntervalSet {
    var following = atn.nextTokens(stateNumber)
    if !following.contains(TokenType.epsilon) {
      return following
    }
    var expected = IntervalSet()
    expected.addSet(following)
    expected.removeOne(TokenType.epsilon)
    var c = context
    while let cc = c, cc.invokingState >= 0, following.contains(TokenType.epsilon) {
      let rt = atn.states[cc.invokingState].transitions[0]
      following = atn.nextTokens(rt.followState)
      expected.addSet(following)
      expected.removeOne(TokenType.epsilon)
      c = cc.parent
    }
    if following.contains(TokenType.epsilon) {
      expected.addOne(TokenType.eof)
    }
    return expected
  }

  // MARK: - Error listener (cel-go parser.SyntaxError)

  func notifyErrorListeners(_ msg: String, _ offendingToken: Token?) throws {
    let token = try offendingToken ?? currentToken()
    try syntaxError(line: token.line, column: token.column, msg)
  }

  private func syntaxError(line: Int, column: Int, _ message: String) throws {
    let offset = sourceInfo.computeOffset(line: Int32(line), column: Int32(column))
    let l = sourceInfo.location(ofOffset: offset)
    var msg = message
    if msg.contains("no viable alternative") {
      msg = ParserRuntime.replaceReservedIdentifier(msg)
    }
    if errorReports < errorReportingLimit {
      errorReports += 1
      errors.reportError(at: l, "Syntax error: " + msg)
    } else {
      errors.reportError(at: l, "Syntax error: More than \(errorReportingLimit) syntax errors")
      throw ParseAbort.tooManyErrors
    }
  }

  /// cel-go rewrites `no viable alternative at input '.(true|false|null)'` to
  /// `mismatched input '$1' expecting IDENTIFIER` (regexp `ReplaceAllString`).
  static func replaceReservedIdentifier(_ msg: String) -> String {
    let prefix = Array("no viable alternative at input '".unicodeScalars)
    let words = ["true", "false", "null"].map { Array($0.unicodeScalars) }
    let s = Array(msg.unicodeScalars)
    var out = String.UnicodeScalarView()
    var i = 0
    outer: while i < s.count {
      if i + prefix.count < s.count, Array(s[i..<(i + prefix.count)]) == prefix,
        s[i + prefix.count] != "\n"
      {
        let afterAny = i + prefix.count + 1
        for w in words {
          let end = afterAny + w.count
          if end < s.count, Array(s[afterAny..<end]) == w, s[end] == "'" {
            out.append(contentsOf: "mismatched input '".unicodeScalars)
            out.append(contentsOf: w)
            out.append(contentsOf: "' expecting IDENTIFIER".unicodeScalars)
            i = end + 1
            continue outer
          }
        }
      }
      out.append(s[i])
      i += 1
    }
    return String(out)
  }

  // MARK: - Error strategy

  private func beginErrorCondition() {
    errorRecoveryMode = true
  }

  private func endErrorCondition() {
    errorRecoveryMode = false
    lastErrorStates = nil
    lastErrorIndex = -1
  }

  func reportMatch() {
    endErrorCondition()
  }

  /// antlr `DefaultErrorStrategy.ReportError`.
  func reportError(_ e: RecognitionException) throws {
    if errorRecoveryMode {
      return
    }
    beginErrorCondition()
    switch e.kind {
    case .noViableAlt(let startToken, let offendingToken):
      let input: String
      if startToken.type == TokenType.eof {
        input = "<EOF>"
      } else {
        input = try text(from: startToken.tokenIndex, to: offendingToken.tokenIndex)
      }
      try notifyErrorListeners(
        "no viable alternative at input " + ParserRuntime.escapeWSAndQuote(input), offendingToken)
    case .inputMismatch(let offendingToken):
      let expecting = expectedTokens(e.offendingState, e.ctx)
      let msg =
        "mismatched input " + ParserRuntime.tokenErrorDisplay(offendingToken) + " expecting "
        + expecting.toTokenString(
          literalNames: CELToken.literalNames, symbolicNames: CELToken.symbolicNames)
      try notifyErrorListeners(msg, offendingToken)
    case .failedPredicate(let message, let offendingToken):
      let ruleName = CELRule.names[ctx?.ruleIndex ?? 0]
      try notifyErrorListeners("rule " + ruleName + " " + message, offendingToken)
    }
  }

  /// cel-go `recoveryLimitErrorStrategy.Recover` around antlr `DefaultErrorStrategy.Recover`.
  func recover(_ e: RecognitionException) throws {
    try checkAttempts()
    lookaheadAttempts = 0
    if lastErrorIndex == tokenIndex, let states = lastErrorStates, states.contains(state) {
      try countedConsume()
    }
    lastErrorIndex = tokenIndex
    if lastErrorStates == nil {
      lastErrorStates = IntervalSet()
    }
    lastErrorStates?.addOne(state)
    let followSet = errorRecoverySet()
    try consumeUntil(followSet, counted: true)
  }

  /// cel-go `recoveryLimitErrorStrategy.RecoverInline` around antlr `DefaultErrorStrategy.RecoverInline`.
  func recoverInline() throws -> Token? {
    try checkAttempts()
    lookaheadAttempts = 0
    if let matched = try singleTokenDeletion(counted: true) {
      try countedConsume()
      return matched
    }
    if try singleTokenInsertion() {
      return try missingSymbol()
    }
    error = try inputMismatch()
    return nil
  }

  private func checkAttempts() throws {
    if recoveryAttempts == errorRecoveryLimit {
      recoveryAttempts += 1
      let msg = "error recovery attempt limit exceeded: \(errorRecoveryLimit)"
      try notifyErrorListeners(msg, nil)
      throw ParseAbort.recoveryLimit
    }
    recoveryAttempts += 1
  }

  /// cel-go `lookaheadConsumer.Consume`: consumption during recovery is limited.
  private func countedConsume() throws {
    if lookaheadAttempts >= lookaheadLimit {
      throw ParseAbort.lookahead(
        "error recovery token lookahead limit exceeded: \(lookaheadLimit)")
    }
    lookaheadAttempts += 1
    try consume()
  }

  /// antlr `DefaultErrorStrategy.Sync`.
  func sync() throws {
    if errorRecoveryMode {
      return
    }
    let s = atn.states[state]
    let lookahead = try la(1)
    let nextTokens = atn.nextTokens(state)
    if nextTokens.contains(TokenType.epsilon) || nextTokens.contains(lookahead) {
      return
    }
    switch s.type {
    case .blockStart, .starBlockStart, .plusBlockStart, .starLoopEntry:
      if try singleTokenDeletion(counted: false) != nil {
        return
      }
      error = try inputMismatch()
    case .plusLoopBack, .starLoopBack:
      try reportUnwantedToken()
      var expecting = IntervalSet()
      expecting.addSet(expectedTokens())
      let whatFollowsLoopIterationOrRule = expecting.addSet(errorRecoverySet())
      try consumeUntil(whatFollowsLoopIterationOrRule, counted: false)
    default:
      break
    }
  }

  private func inputMismatch() throws -> RecognitionException {
    RecognitionException(
      kind: .inputMismatch(offendingToken: try currentToken()), offendingState: state, ctx: ctx)
  }

  func noViableAltHere() throws -> RecognitionException {
    let t = try currentToken()
    return RecognitionException(
      kind: .noViableAlt(startToken: t, offendingToken: t), offendingState: state, ctx: ctx)
  }

  func failedPredicate(_ predicate: String) throws -> RecognitionException {
    RecognitionException(
      kind: .failedPredicate(
        message: "failed predicate: {" + predicate + "}?", offendingToken: try currentToken()),
      offendingState: state, ctx: ctx)
  }

  private func reportUnwantedToken() throws {
    if errorRecoveryMode {
      return
    }
    beginErrorCondition()
    let t = try currentToken()
    let msg =
      "extraneous input " + ParserRuntime.tokenErrorDisplay(t) + " expecting "
      + expectedTokens().toTokenString(
        literalNames: CELToken.literalNames, symbolicNames: CELToken.symbolicNames)
    try notifyErrorListeners(msg, t)
  }

  private func reportMissingToken() throws {
    if errorRecoveryMode {
      return
    }
    beginErrorCondition()
    let t = try currentToken()
    let msg =
      "missing "
      + expectedTokens().toTokenString(
        literalNames: CELToken.literalNames, symbolicNames: CELToken.symbolicNames)
      + " at " + ParserRuntime.tokenErrorDisplay(t)
    try notifyErrorListeners(msg, t)
  }

  private func singleTokenInsertion() throws -> Bool {
    let currentSymbolType = try la(1)
    let next = atn.states[state].transitions[0].target
    let expectingAtLL2 = atn.nextTokens(next, ctx: PredictionContext.from(atn, ctx))
    if expectingAtLL2.contains(currentSymbolType) {
      try reportMissingToken()
      return true
    }
    return false
  }

  private func singleTokenDeletion(counted: Bool) throws -> Token? {
    let nextTokenType = try la(2)
    let expecting = expectedTokens()
    if expecting.contains(nextTokenType) {
      try reportUnwantedToken()
      if counted {
        try countedConsume()
      } else {
        try consume()
      }
      let matchedSymbol = try currentToken()
      reportMatch()
      return matchedSymbol
    }
    return nil
  }

  private func missingSymbol() throws -> Token {
    let currentSymbol = try currentToken()
    let expectedTokenType = expectedTokens().first
    let tokenText: String
    if expectedTokenType == TokenType.eof {
      tokenText = "<missing EOF>"
    } else if expectedTokenType > 0 && expectedTokenType < CELToken.literalNames.count {
      tokenText = "<missing " + CELToken.literalNames[expectedTokenType] + ">"
    } else {
      tokenText = "<missing undefined>"
    }
    var current = currentSymbol
    if current.type == TokenType.eof, let lookback = try lt(-1) {
      current = lookback
    }
    return Token(
      type: expectedTokenType, channel: CELToken.defaultChannel, start: -1, stop: -1,
      line: current.line, column: current.column, tokenIndex: -1, text: tokenText)
  }

  static func tokenErrorDisplay(_ t: Token) -> String {
    var s = t.text
    if s.isEmpty {
      s = t.type == TokenType.eof ? "<EOF>" : "<\(t.type)>"
    }
    return escapeWSAndQuote(s)
  }

  static func escapeWSAndQuote(_ s: String) -> String {
    var out = "'"
    for scalar in s.unicodeScalars {
      switch scalar {
      case "\t": out += "\\t"
      case "\n": out += "\\n"
      case "\r": out += "\\r"
      default: out.unicodeScalars.append(scalar)
      }
    }
    return out + "'"
  }

  private func errorRecoverySet() -> IntervalSet {
    var recoverSet = IntervalSet()
    var c = ctx
    while let cc = c, cc.invokingState >= 0 {
      let rt = atn.states[cc.invokingState].transitions[0]
      recoverSet.addSet(atn.nextTokens(rt.followState))
      c = cc.parent
    }
    recoverSet.removeOne(TokenType.epsilon)
    return recoverSet
  }

  private func consumeUntil(_ set: IntervalSet, counted: Bool) throws {
    var ttype = try la(1)
    while ttype != TokenType.eof && !set.contains(ttype) {
      if counted {
        try countedConsume()
      } else {
        try consume()
      }
      ttype = try la(1)
    }
  }

  /// The generated `errorExit` block: report and recover from a pending error.
  func handleErrorExit(_ localctx: ParserRuleContext) throws {
    if let v = error {
      localctx.exception = v
      try reportError(v)
      try recover(v)
      error = nil
    }
  }

  // MARK: - Adaptive prediction (antlr ParserATNSimulator)

  /// antlr `AdaptivePredict`. Sets `error` on failure and returns 0 (ATNInvalidAltNumber).
  func adaptivePredict(_ decision: Int) throws -> Int {
    let outer = ctx
    startIndex = tokenIndex
    outerContext = outer
    let dfa = cache.decisionToDFA[decision]
    currentDFA = dfa
    let index = tokenIndex
    let precedence = precedence
    var s0: DFAState? = cache.stateLock.withReadLock {
      if dfa.precedenceDfa {
        return cache.edgeLock.withReadLock { dfa.precedenceStartState(precedence) }
      }
      return dfa.s0
    }
    if s0 == nil {
      // Computed outside the locks; a parse that races us to it publishes an equal state, which
      // addDFAState then returns to both.
      if let snapshot = ParserRuntime.startStateSnapshot(decision, precedence) {
        // The SLL start state depends only on the ATN and the precedence: reuse the precomputed one.
        let configs = snapshot.materialize()
        s0 = cache.stateLock.withWriteLock {
          let start = addDFAState(dfa, DFAState(stateNumber: -1, configs: configs))
          if dfa.precedenceDfa {
            cache.edgeLock.withWriteLock { dfa.setPrecedenceStartState(precedence, start) }
          } else {
            dfa.s0 = start
          }
          return start
        }
      } else {
        let s0Closure = computeStartState(dfa.atnStartState, nil, fullCtx: false)
        let filtered = dfa.precedenceDfa ? applyPrecedenceFilter(s0Closure) : s0Closure
        s0 = cache.stateLock.withWriteLock {
          let start = addDFAState(dfa, DFAState(stateNumber: -1, configs: filtered))
          if dfa.precedenceDfa {
            dfa.s0?.configs = s0Closure
            cache.edgeLock.withWriteLock { dfa.setPrecedenceStartState(precedence, start) }
          } else {
            dfa.s0 = start
          }
          return start
        }
      }
    }
    guard let s0 else {
      preconditionFailure("no start state")
    }
    let (alt, re) = try execATN(dfa, s0, index, outer)
    error = re
    currentDFA = nil
    mergeCache = nil
    try seek(index)
    return alt
  }

  /// SLL start states per decision; precedence decisions have one per precedence 0...3.
  private static let startStates: [[Int: ConfigSetSnapshot]] = {
    let runtime = ParserRuntime(
      input: [], sourceInfo: SourceInfo(source: nil), errors: CELErrors(), maxRecursionDepth: 1,
      errorReportingLimit: 1, errorRecoveryLimit: 1, lookaheadLimit: 1,
      cache: PredictionCache(atn: celParserATN))
    return runtime.computeAllStartStates()
  }()

  static func startStateSnapshot(_ decision: Int, _ precedence: Int) -> ConfigSetSnapshot? {
    let byPrecedence = startStates[decision]
    if let plain = byPrecedence[-1] {
      return plain
    }
    return byPrecedence[precedence]
  }

  private func computeAllStartStates() -> [[Int: ConfigSetSnapshot]] {
    var out: [[Int: ConfigSetSnapshot]] = []
    for decision in atn.decisionToState.indices {
      let dfa = DFA(atn: atn, decision: decision)
      currentDFA = dfa
      var byPrecedence: [Int: ConfigSetSnapshot] = [:]
      if dfa.precedenceDfa {
        for p in 0...3 {
          precedenceStack = [0, p]
          let closure = computeStartState(dfa.atnStartState, nil, fullCtx: false)
          byPrecedence[p] = ConfigSetSnapshot(applyPrecedenceFilter(closure))
        }
        precedenceStack = [0]
      } else {
        byPrecedence[-1] = ConfigSetSnapshot(
          computeStartState(dfa.atnStartState, nil, fullCtx: false))
      }
      currentDFA = nil
      out.append(byPrecedence)
    }
    return out
  }

  private func execATN(
    _ dfa: DFA, _ s0: DFAState, _ startIndex: Int, _ outerContext: ParserRuleContext?
  ) throws -> (Int, RecognitionException?) {
    var previousD = s0
    var t = try la(1)
    while true {
      var target = existingTargetState(previousD, t)
      if target == nil {
        target = try computeTargetState(dfa, previousD, t)
      }
      guard let d = target else {
        preconditionFailure("no target state")
      }
      if d === errorState {
        let e = try noViableAlt(outerContext, startIndex)
        try seek(startIndex)
        let alt = getSynValidOrSemInvalidAltThatFinishedDecisionEntryRule(
          previousD.configs, outerContext)
        if alt != 0 {
          return (alt, nil)
        }
        error = e
        return (0, e)
      }
      if d.requiresFullContext {
        if let predicates = d.predicates {
          let conflictIndex = tokenIndex
          if conflictIndex != startIndex {
            try seek(startIndex)
          }
          let conflictingAlts = evalSemanticContext(predicates, outerContext, complete: true)
          if conflictingAlts.length == 1 {
            return (conflictingAlts.minValue, nil)
          }
          if conflictIndex != startIndex {
            try seek(conflictIndex)
          }
        }
        let s0Closure = computeStartState(dfa.atnStartState, outerContext, fullCtx: true)
        return try execATNWithFullContext(dfa, d, s0Closure, startIndex, outerContext)
      }
      if d.isAcceptState {
        guard let predicates = d.predicates else {
          return (d.prediction, nil)
        }
        try seek(startIndex)
        let alts = evalSemanticContext(predicates, outerContext, complete: true)
        switch alts.length {
        case 0:
          return (0, try noViableAlt(outerContext, startIndex))
        default:
          return (alts.minValue, nil)
        }
      }
      previousD = d
      if t != TokenType.eof {
        try consumeToken()
        t = try la(1)
      }
    }
  }

  private func existingTargetState(_ previousD: DFAState, _ t: Int) -> DFAState? {
    guard t + 1 >= 0 else {
      return nil
    }
    return cache.edgeLock.withReadLock {
      guard let count = previousD.edges?.count, t + 1 < count else {
        return nil
      }
      return previousD.edges?[t + 1] ?? nil
    }
  }

  private func computeTargetState(_ dfa: DFA, _ previousD: DFAState, _ t: Int) throws -> DFAState {
    guard let reach = computeReachSet(previousD.configs, t, fullCtx: false) else {
      _ = addDFAEdge(dfa, previousD, t, errorState)
      return errorState
    }
    var d = DFAState(stateNumber: -1, configs: reach)
    let predictedAlt = uniqueAlt(reach)
    if predictedAlt != 0 {
      d.isAcceptState = true
      d.configs.uniqueAlt = predictedAlt
      d.prediction = predictedAlt
    } else if PredictionMode.hasSLLConflictTerminatingPrediction(reach, atn) {
      let conflicting = conflictingAlts(reach)
      d.configs.conflictingAlts = conflicting
      d.requiresFullContext = true
      d.isAcceptState = true
      d.prediction = conflicting.minValue
    }
    if d.isAcceptState && d.configs.hasSemanticContext {
      predicateDFAState(d, dfa.atnStartState)
      if d.predicates != nil {
        d.prediction = 0
      }
    }
    d = addDFAEdge(dfa, previousD, t, d)
    return d
  }

  private func predicateDFAState(_ dfaState: DFAState, _ decisionState: Int) {
    let nalts = atn.states[decisionState].transitions.count
    var altsToCollectPredsFrom = BitSet()
    if dfaState.configs.uniqueAlt != 0 {
      altsToCollectPredsFrom.add(dfaState.configs.uniqueAlt)
    } else if let conflicting = dfaState.configs.conflictingAlts {
      altsToCollectPredsFrom = conflicting
    }
    if let altToPred = predsForAmbigAlts(altsToCollectPredsFrom, dfaState.configs, nalts) {
      dfaState.predicates = predicatePredictions(altsToCollectPredsFrom, altToPred)
      dfaState.prediction = 0
    } else {
      dfaState.prediction = altsToCollectPredsFrom.minValue
    }
  }

  private func execATNWithFullContext(
    _ dfa: DFA, _ d: DFAState, _ s0: ATNConfigSet, _ startIndex: Int,
    _ outerContext: ParserRuleContext?
  ) throws -> (Int, RecognitionException?) {
    var previous = s0
    try seek(startIndex)
    var t = try la(1)
    var predictedAlt = -1
    while true {
      guard let reach = computeReachSet(previous, t, fullCtx: true) else {
        try seek(startIndex)
        let alt = getSynValidOrSemInvalidAltThatFinishedDecisionEntryRule(previous, outerContext)
        if alt != 0 {
          return (alt, nil)
        }
        return (alt, try noViableAlt(outerContext, startIndex))
      }
      let altSubSets = PredictionMode.conflictingAltSubsets(reach)
      reach.uniqueAlt = uniqueAlt(reach)
      if reach.uniqueAlt != 0 {
        predictedAlt = reach.uniqueAlt
        break
      }
      predictedAlt = PredictionMode.singleViableAlt(altSubSets)
      if predictedAlt != 0 {
        break
      }
      previous = reach
      if t != TokenType.eof {
        try consumeToken()
        t = try la(1)
      }
    }
    return (predictedAlt, nil)
  }

  private func computeReachSet(_ closure: ATNConfigSet, _ t: Int, fullCtx: Bool) -> ATNConfigSet? {
    if mergeCache == nil {
      mergeCache = MergeCache()
    }
    let intermediate = ATNConfigSet(fullCtx: fullCtx)
    var skippedStopStates: [ATNConfig]? = nil
    for c in closure.configs {
      let state = atn.states[c.state]
      if state.type == .ruleStop {
        if fullCtx || t == TokenType.eof {
          skippedStopStates = (skippedStopStates ?? []) + [c]
        }
        continue
      }
      for trans in state.transitions where trans.matches(t, 0, atn.maxTokenType) {
        intermediate.add(ATNConfig(c, state: trans.target), mergeCache)
      }
    }
    var reach: ATNConfigSet? = nil
    if skippedStopStates == nil && t != TokenType.eof {
      if intermediate.configs.count == 1 {
        reach = intermediate
      } else if uniqueAlt(intermediate) != 0 {
        reach = intermediate
      }
    }
    var result: ATNConfigSet
    if let reach {
      result = reach
    } else {
      result = ATNConfigSet(fullCtx: fullCtx)
      var closureBusy = Set<ConfigEqualityKey>()
      let treatEOFAsEpsilon = t == TokenType.eof
      for c in intermediate.configs {
        self.closure(
          c, result, &closureBusy, collectPredicates: false, fullCtx: fullCtx,
          treatEOFAsEpsilon: treatEOFAsEpsilon)
      }
    }
    if t == TokenType.eof {
      result = removeAllConfigsNotInRuleStopState(result, lookToEndOfRule: result.equals(intermediate))
    }
    if let skippedStopStates,
      !fullCtx || !PredictionMode.hasConfigInRuleStopState(result, atn)
    {
      for c in skippedStopStates {
        result.add(c, mergeCache)
      }
    }
    if result.configs.isEmpty {
      return nil
    }
    return result
  }

  private func removeAllConfigsNotInRuleStopState(_ configs: ATNConfigSet, lookToEndOfRule: Bool)
    -> ATNConfigSet
  {
    if PredictionMode.allConfigsInRuleStopStates(configs, atn) {
      return configs
    }
    let result = ATNConfigSet(fullCtx: configs.fullCtx)
    for config in configs.configs {
      let state = atn.states[config.state]
      if state.type == .ruleStop {
        result.add(config, mergeCache)
        continue
      }
      if lookToEndOfRule && state.epsilonOnlyTransitions {
        if atn.nextTokens(config.state).contains(TokenType.epsilon) {
          let endOfRuleState = atn.ruleToStopState[state.ruleIndex]
          result.add(ATNConfig(config, state: endOfRuleState), mergeCache)
        }
      }
    }
    return result
  }

  private func computeStartState(_ a: Int, _ ctx: ParserRuleContext?, fullCtx: Bool) -> ATNConfigSet {
    let initialContext = PredictionContext.from(atn, ctx)
    let configs = ATNConfigSet(fullCtx: fullCtx)
    for (i, t) in atn.states[a].transitions.enumerated() {
      let c = ATNConfig(state: t.target, alt: i + 1, context: initialContext)
      var closureBusy = Set<ConfigEqualityKey>()
      closure(c, configs, &closureBusy, collectPredicates: true, fullCtx: fullCtx, treatEOFAsEpsilon: false)
    }
    return configs
  }

  private func applyPrecedenceFilter(_ configs: ATNConfigSet) -> ATNConfigSet {
    var statesFromAlt1: [Int: PredictionContext?] = [:]
    let configSet = ATNConfigSet(fullCtx: configs.fullCtx)
    for config in configs.configs where config.alt == 1 {
      guard let updated = config.semanticContext.evalPrecedence(self, outerContext) else {
        continue
      }
      statesFromAlt1[config.state] = .some(config.context)
      if updated != config.semanticContext {
        configSet.add(ATNConfig(config, semanticContext: updated), mergeCache)
      } else {
        configSet.add(config, mergeCache)
      }
    }
    for config in configs.configs where config.alt != 1 {
      if !config.precedenceFilterSuppressed {
        if let stored = statesFromAlt1[config.state], let context = stored,
          context.equals(config.context)
        {
          continue
        }
      }
      configSet.add(config, mergeCache)
    }
    return configSet
  }

  private func predsForAmbigAlts(_ ambigAlts: BitSet, _ configs: ATNConfigSet, _ nalts: Int)
    -> [SemanticContext]?
  {
    var altToPred = [SemanticContext?](repeating: nil, count: nalts + 1)
    for c in configs.configs where ambigAlts.contains(c.alt) {
      altToPred[c.alt] = SemanticContext.orContext(altToPred[c.alt], c.semanticContext)
    }
    var nPredAlts = 0
    if nalts >= 1 {
      for i in 1...nalts {
        if altToPred[i] == nil {
          altToPred[i] = SemanticContext.none
        } else if altToPred[i] != SemanticContext.none {
          nPredAlts += 1
        }
      }
    }
    if nPredAlts == 0 {
      return nil
    }
    return altToPred.map { $0 ?? .none }
  }

  private func predicatePredictions(_ ambigAlts: BitSet, _ altToPred: [SemanticContext])
    -> [PredPrediction]?
  {
    var pairs: [PredPrediction] = []
    var containsPredicate = false
    for i in 1..<altToPred.count {
      let pred = altToPred[i]
      if ambigAlts.contains(i) {
        pairs.append(PredPrediction(pred: pred, alt: i))
      }
      if pred != .none {
        containsPredicate = true
      }
    }
    return containsPredicate ? pairs : nil
  }

  private func getSynValidOrSemInvalidAltThatFinishedDecisionEntryRule(
    _ configs: ATNConfigSet, _ outerContext: ParserRuleContext?
  ) -> Int {
    let succeeded = ATNConfigSet(fullCtx: configs.fullCtx)
    let failed = ATNConfigSet(fullCtx: configs.fullCtx)
    for c in configs.configs {
      if c.semanticContext != .none {
        if c.semanticContext.evaluate(self, outerContext) {
          succeeded.add(c)
        } else {
          failed.add(c)
        }
      } else {
        succeeded.add(c)
      }
    }
    var alt = altThatFinishedDecisionEntryRule(succeeded)
    if alt != 0 {
      return alt
    }
    if !failed.isEmpty {
      alt = altThatFinishedDecisionEntryRule(failed)
      if alt != 0 {
        return alt
      }
    }
    return 0
  }

  private func altThatFinishedDecisionEntryRule(_ configs: ATNConfigSet) -> Int {
    var alts = IntervalSet()
    for c in configs.configs {
      let isStop = atn.states[c.state].type == .ruleStop
      if c.reachesIntoOuterContext > 0 || (isStop && (c.context?.hasEmptyPath ?? false)) {
        alts.addOne(c.alt)
      }
    }
    if alts.length == 0 {
      return 0
    }
    return alts.first
  }

  private func evalSemanticContext(
    _ predPredictions: [PredPrediction], _ outerContext: ParserRuleContext?, complete: Bool
  ) -> BitSet {
    var predictions = BitSet()
    for pair in predPredictions {
      if pair.pred == .none {
        predictions.add(pair.alt)
        if !complete {
          break
        }
        continue
      }
      if pair.pred.evaluate(self, outerContext) {
        predictions.add(pair.alt)
        if !complete {
          break
        }
      }
    }
    return predictions
  }

  private func closure(
    _ config: ATNConfig, _ configs: ATNConfigSet, _ closureBusy: inout Set<ConfigEqualityKey>,
    collectPredicates: Bool, fullCtx: Bool, treatEOFAsEpsilon: Bool
  ) {
    closureCheckingStopState(
      config, configs, &closureBusy, collectPredicates, fullCtx, 0, treatEOFAsEpsilon)
  }

  private func closureCheckingStopState(
    _ config: ATNConfig, _ configs: ATNConfigSet, _ closureBusy: inout Set<ConfigEqualityKey>,
    _ collectPredicates: Bool, _ fullCtx: Bool, _ depth: Int, _ treatEOFAsEpsilon: Bool
  ) {
    var stack = [config]
    while let currConfig = stack.popLast() {
      if atn.states[currConfig.state].type == .ruleStop, let context = currConfig.context {
        if !context.isEmpty {
          for i in 0..<context.length {
            if context.returnState(i) == PredictionContext.emptyReturnState {
              if fullCtx {
                let nb = ATNConfig(currConfig, state: currConfig.state, context: .some(PredictionContext.empty))
                configs.add(nb, mergeCache)
                continue
              } else {
                closureWork(
                  currConfig, configs, &closureBusy, collectPredicates, fullCtx, depth,
                  treatEOFAsEpsilon)
              }
              continue
            }
            let returnState = context.returnState(i)
            let newContext = context.parent(i)
            let c = ATNConfig(
              state: returnState, alt: currConfig.alt, context: newContext,
              semanticContext: currConfig.semanticContext)
            c.reachesIntoOuterContext = currConfig.reachesIntoOuterContext
            stack.append(c)
          }
          continue
        } else if fullCtx {
          configs.add(currConfig, mergeCache)
          continue
        }
      }
      closureWork(
        currConfig, configs, &closureBusy, collectPredicates, fullCtx, depth, treatEOFAsEpsilon)
    }
  }

  private func closureWork(
    _ config: ATNConfig, _ configs: ATNConfigSet, _ closureBusy: inout Set<ConfigEqualityKey>,
    _ collectPredicates: Bool, _ fullCtx: Bool, _ depth: Int, _ treatEOFAsEpsilon: Bool
  ) {
    let state = atn.states[config.state]
    if !state.epsilonOnlyTransitions {
      configs.add(config, mergeCache)
    }
    for (i, t) in state.transitions.enumerated() {
      if i == 0 && canDropLoopEntryEdgeInLeftRecursiveRule(config) {
        continue
      }
      let continueCollecting = collectPredicates && t.kind != .action
      guard
        let c = epsilonTarget(
          config, t, collectPredicates: continueCollecting, inContext: depth == 0, fullCtx: fullCtx,
          treatEOFAsEpsilon: treatEOFAsEpsilon)
      else {
        continue
      }
      var newDepth = depth
      if state.type == .ruleStop {
        if let dfa = currentDFA, dfa.precedenceDfa {
          if t.outermostPrecedenceReturn == atn.states[dfa.atnStartState].ruleIndex {
            c.precedenceFilterSuppressed = true
          }
        }
        c.reachesIntoOuterContext += 1
        if !closureBusy.insert(ConfigEqualityKey(c)).inserted {
          continue
        }
        configs.dipsIntoOuterContext = true
        newDepth -= 1
      } else {
        if !t.isEpsilon {
          if !closureBusy.insert(ConfigEqualityKey(c)).inserted {
            continue
          }
        }
        if t.kind == .rule {
          if newDepth >= 0 {
            newDepth += 1
          }
        }
      }
      closureCheckingStopState(
        c, configs, &closureBusy, continueCollecting, fullCtx, newDepth, treatEOFAsEpsilon)
    }
  }

  private func canDropLoopEntryEdgeInLeftRecursiveRule(_ config: ATNConfig) -> Bool {
    let p = atn.states[config.state]
    guard p.type == .starLoopEntry, p.precedenceRuleDecision, let context = config.context,
      !context.isEmpty, !context.hasEmptyPath
    else {
      return false
    }
    let numCtxs = context.length
    for i in 0..<numCtxs where atn.states[context.returnState(i)].ruleIndex != p.ruleIndex {
      return false
    }
    let decisionStartState = atn.states[p.transitions[0].target]
    let blockEndState = decisionStartState.endState
    for i in 0..<numCtxs {
      let returnStateNumber = context.returnState(i)
      let returnState = atn.states[returnStateNumber]
      if returnState.transitions.count != 1 || !returnState.transitions[0].isEpsilon {
        return false
      }
      let returnStateTarget = returnState.transitions[0].target
      if returnState.type == .blockEnd && returnStateTarget == p.stateNumber {
        continue
      }
      if returnStateNumber == blockEndState {
        continue
      }
      if returnStateTarget == blockEndState {
        continue
      }
      let rst = atn.states[returnStateTarget]
      if rst.type == .blockEnd && rst.transitions.count == 1 && rst.transitions[0].isEpsilon
        && rst.transitions[0].target == p.stateNumber
      {
        continue
      }
      return false
    }
    return true
  }

  private func epsilonTarget(
    _ config: ATNConfig, _ t: Transition, collectPredicates: Bool, inContext: Bool, fullCtx: Bool,
    treatEOFAsEpsilon: Bool
  ) -> ATNConfig? {
    switch t.kind {
    case .rule:
      let newContext = PredictionContext.singleton(parent: config.context, returnState: t.followState)
      return ATNConfig(config, state: t.target, context: .some(newContext))
    case .precedence:
      if collectPredicates && inContext {
        if fullCtx {
          return precpred(t.arg1) ? ATNConfig(config, state: t.target) : nil
        }
        let newSemCtx = SemanticContext.andContext(config.semanticContext, .precedence(t.arg1))
        return ATNConfig(config, state: t.target, semanticContext: newSemCtx)
      }
      return ATNConfig(config, state: t.target)
    case .predicate:
      if collectPredicates && (!t.isCtxDependent || inContext) {
        let pred = SemanticContext.predicate(
          ruleIndex: t.arg1, predIndex: t.arg2, isCtxDependent: t.isCtxDependent)
        if fullCtx {
          return pred.evaluate(self, outerContext) ? ATNConfig(config, state: t.target) : nil
        }
        let newSemCtx = SemanticContext.andContext(config.semanticContext, pred)
        return ATNConfig(config, state: t.target, semanticContext: newSemCtx)
      }
      return ATNConfig(config, state: t.target)
    case .action, .epsilon:
      return ATNConfig(config, state: t.target)
    case .atom, .range, .set:
      if treatEOFAsEpsilon && t.matches(TokenType.eof, 0, 1) {
        return ATNConfig(config, state: t.target)
      }
      return nil
    default:
      return nil
    }
  }

  private func noViableAlt(_ outerContext: ParserRuleContext?, _ startIndex: Int) throws
    -> RecognitionException
  {
    let offending = try currentToken()
    return RecognitionException(
      kind: .noViableAlt(startToken: tokens[startIndex], offendingToken: offending),
      offendingState: state, ctx: outerContext)
  }

  private func uniqueAlt(_ configs: ATNConfigSet) -> Int {
    var alt = 0
    for c in configs.configs {
      if alt == 0 {
        alt = c.alt
      } else if c.alt != alt {
        return 0
      }
    }
    return alt
  }

  private func conflictingAlts(_ configs: ATNConfigSet) -> BitSet {
    PredictionMode.alts(PredictionMode.conflictingAltSubsets(configs))
  }

  /// antlr `addDFAEdge`: publishes `to` (or the equal state already in the DFA) and links it from
  /// `from`, taking each lock only for its own step.
  private func addDFAEdge(_ dfa: DFA, _ from: DFAState, _ t: Int, _ to: DFAState) -> DFAState {
    let to = cache.stateLock.withWriteLock { addDFAState(dfa, to) }
    if t < -1 || t > atn.maxTokenType {
      return to
    }
    cache.edgeLock.withWriteLock {
      if from.edges == nil {
        from.edges = Array(repeating: nil, count: atn.maxTokenType + 2)
      }
      from.edges?[t + 1] = to
    }
    return to
  }

  /// antlr `addDFAState`. The caller holds `cache.stateLock` for writing; `d` must not be shared yet.
  private func addDFAState(_ dfa: DFA, _ d: DFAState) -> DFAState {
    if d === errorState {
      return d
    }
    if let existing = dfa.get(d) {
      return existing
    }
    d.stateNumber = dfa.count
    d.configs.makeReadOnly()
    dfa.put(d)
    return d
  }
}

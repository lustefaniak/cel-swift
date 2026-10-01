// Reproducers for findings of the libFuzzer targets (Fuzz/README.md). Each test names the input in
// Fuzz/regressions/<target>/ it comes from, or the finding when it is not an input.

import Testing

@testable import CEL

struct FuzzRegressionTests {
  /// Every fuzzer ran out of memory within minutes (rss_limit_mb 2048): each parse leaked its
  /// prediction DFA, whose states point at each other through their edges, a retain cycle. The
  /// DFA is per parse, so it must release its states with it.
  @Test func dfaReleasesStatesWithEdgeCycles() {
    weak var released: DFAState?
    do {
      let dfa = DFA(atn: celParserATN, decision: 0)
      let state = DFAState(stateNumber: 0, configs: ATNConfigSet(fullCtx: false))
      state.edges = [state]
      dfa.put(state)
      released = state
      #expect(dfa.count == 1)
    }
    #expect(released == nil)
  }

  /// With the DFA fixed, inputs with syntax errors still leaked their parse tree: the rule context
  /// records its exception, and the exception pointed back at the context.
  @Test func syntaxErrorReleasesItsParseTree() {
    weak var released: ParserRuleContext?
    do {
      let ctx = ParserRuleContext(parent: nil, invokingState: -1, ruleIndex: 0, label: .start)
      let token = Token(type: 1, channel: 0, start: 0, stop: 0, line: 1, column: 0, tokenIndex: 0, text: "x")
      ctx.exception = RecognitionException(kind: .inputMismatch(offendingToken: token), offendingState: 0, ctx: ctx)
      released = ctx
    }
    #expect(released == nil)
  }
}

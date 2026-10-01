// The bodies of the libFuzzer targets, shared by the targets (Sources/cel-fuzz-*) and by
// cel-fuzz-leakcheck, which replays a corpus through them without libFuzzer. Not a ported file.

import CEL

/// One fuzz target: what a single input runs through.
package enum FuzzTarget: String, CaseIterable, Sendable {
  case parser, checker, evaluator

  /// Runs one input through the target.
  package func run(_ text: String) {
    switch self {
    case .parser: FuzzTargets.parse(text)
    case .checker: FuzzTargets.check(text)
    case .evaluator: FuzzTargets.evaluate(text)
    }
  }
}

package enum FuzzTargets {
  // MARK: Parser

  private static let parsers: [Parser] = [
    // The fuzz environment's parser: all macros, optional syntax, identifier escapes.
    try! Parser(
      options: [.macros(FuzzSupport.environment.macros)] + FuzzSupport.environment.parserOptions),
    // cel-go parser_test.go limits, with error recovery.
    try! Parser(options: [
      .macros(Macro.allMacros), .maxRecursionDepth(32), .errorRecoveryLimit(4),
      .errorRecoveryLookaheadTokenLimit(4), .enableVariadicOperatorASTs(true),
    ]),
  ]

  /// Lexer, parser, macro expansion, debug printer and unparser, then a parse of the unparsed text.
  package static func parse(_ text: String) {
    for parser in parsers {
      let (ast, errors) = parser.parse(TextSource(text, description: "<fuzz>"))
      if !errors.isEmpty {
        _ = errors.toDisplayString()
        continue
      }
      _ = ExprDebug.toDebugStringWithIDs(ast.expr)
      if let unparsed = try? Unparser.unparse(ast.expr, sourceInfo: ast.sourceInfo) {
        _ = parser.parse(TextSource(unparsed, description: "<unparsed>"))
      }
    }
  }

  // MARK: Checker

  private static let checkerEnv = try! FuzzSupport.environment.checkerEnv()

  /// Parse and type-check against the fuzz environment, then print the checked AST or the errors.
  package static func check(_ text: String) {
    guard let ast = try? FuzzSupport.environment.parse(text, description: "<fuzz>") else {
      return
    }
    let (checked, errors) = Checker.check(ast, source: TextSource(text, description: "<fuzz>"), env: checkerEnv)
    if errors.isEmpty {
      _ = Checker.print(checked.expr, checked: checked)
    } else {
      _ = errors.toDisplayString()
    }
  }

  // MARK: Evaluator

  /// Far above what a short expression over the fuzz bindings needs, low enough to stop runaway
  /// comprehensions within the libFuzzer timeout.
  private static let costLimit: UInt64 = 1_000_000
  /// Wall-clock budget per evaluation, checked every 64 comprehension iterations.
  private static let deadline: Duration = .seconds(2)

  private static let programOptions: [ProgramOptions] = [
    ProgramOptions(costLimit: costLimit, interruptCheckFrequency: 64),
    ProgramOptions(evalOptions: [.exhaustiveEval, .optimize], costLimit: costLimit, interruptCheckFrequency: 64),
  ]

  /// Parse, check (else parse-only), estimate the static cost, plan and evaluate, plain and
  /// exhaustive + optimized, with a cost limit and an interrupt deadline.
  package static func evaluate(_ text: String) {
    let env = FuzzSupport.environment
    guard let parsed = try? env.parse(text, description: "<fuzz>") else {
      return
    }
    let ast: AST
    if let checked = try? env.check(parsed, source: TextSource(text, description: "<fuzz>")) {
      _ = Checker.estimateCost(checked)
      ast = checked
    } else {
      ast = parsed
    }
    for options in programOptions {
      guard let program = try? env.program(ast, options: options) else {
        continue
      }
      let clock = ContinuousClock()
      let end = clock.now.advanced(by: deadline)
      let result = program.eval(MapActivation(FuzzSupport.bindings), interrupt: { clock.now >= end })
      _ = result.value.description
    }
  }
}

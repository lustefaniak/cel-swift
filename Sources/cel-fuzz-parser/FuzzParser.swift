// libFuzzer target: lexer, parser, macro expansion, debug printer and unparser.
// Not a ported file; see Fuzz/README.md.

import CEL
import CELFuzzSupport

private let parsers: [Parser] = [
  // The fuzz environment's parser: all macros, optional syntax, identifier escapes.
  try! Parser(
    options: [.macros(FuzzSupport.environment.macros)] + FuzzSupport.environment.parserOptions),
  // cel-go parser_test.go limits, with error recovery.
  try! Parser(options: [
    .macros(Macro.allMacros), .maxRecursionDepth(32), .errorRecoveryLimit(4),
    .errorRecoveryLookaheadTokenLimit(4), .enableVariadicOperatorASTs(true),
  ]),
]

@_cdecl("LLVMFuzzerTestOneInput")
public func fuzz(_ data: UnsafePointer<UInt8>?, _ size: Int) -> CInt {
  let text = FuzzSupport.expression(data, size)
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
  return 0
}

/// The entry point SwiftPM links as `main`.
@_cdecl("cel_fuzz_parser_main")
public func entry(_ argc: CInt, _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> CInt {
  FuzzSupport.runDriver(argc, argv, fuzz)
}

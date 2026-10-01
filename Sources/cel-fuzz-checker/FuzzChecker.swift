// libFuzzer target: parse and type-check against the fuzz environment, then print the checked AST.
// Not a ported file; see Fuzz/README.md.

import CEL
import CELFuzzSupport

private let checkerEnv = try! FuzzSupport.environment.checkerEnv()

@_cdecl("LLVMFuzzerTestOneInput")
public func fuzz(_ data: UnsafePointer<UInt8>?, _ size: Int) -> CInt {
  let text = FuzzSupport.expression(data, size)
  guard let ast = try? FuzzSupport.environment.parse(text, description: "<fuzz>") else {
    return 0
  }
  let (checked, errors) = Checker.check(ast, source: TextSource(text, description: "<fuzz>"), env: checkerEnv)
  if errors.isEmpty {
    _ = Checker.print(checked.expr, checked: checked)
  } else {
    _ = errors.toDisplayString()
  }
  return 0
}

/// The entry point SwiftPM links as `main`.
@_cdecl("cel_fuzz_checker_main")
public func entry(_ argc: CInt, _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> CInt {
  FuzzSupport.runDriver(argc, argv, fuzz)
}

// libFuzzer target: lexer, parser, macro expansion, debug printer and unparser. Not a ported file; see Fuzz/README.md.
// The body is `FuzzTargets.parse` (Sources/CELFuzzSupport/FuzzTargets.swift), which
// cel-fuzz-leakcheck also runs.

import CELFuzzDriver
import CELFuzzSupport

@_cdecl("LLVMFuzzerTestOneInput")
public func fuzz(_ data: UnsafePointer<UInt8>?, _ size: Int) -> CInt {
  FuzzTargets.parse(FuzzSupport.expression(data, size))
  return 0
}

/// The entry point SwiftPM links as `main`: runs libFuzzer's driver.
@_cdecl("cel_fuzz_parser_main")
public func entry(_ argc: CInt, _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> CInt {
  var argc = argc
  var argv = argv
  return LLVMFuzzerRunDriver(&argc, &argv, fuzz)
}

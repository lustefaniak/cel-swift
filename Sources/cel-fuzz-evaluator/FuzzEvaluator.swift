// libFuzzer target: parse, check (else parse-only), estimate, plan and evaluate with a cost limit and an
// interrupt deadline. Not a ported file; see Fuzz/README.md.
// The body is `FuzzTargets.evaluate` (Sources/CELFuzzSupport/FuzzTargets.swift), which
// cel-fuzz-leakcheck also runs.

import CELFuzzDriver
import CELFuzzSupport

@_cdecl("LLVMFuzzerTestOneInput")
public func fuzz(_ data: UnsafePointer<UInt8>?, _ size: Int) -> CInt {
  FuzzTargets.evaluate(FuzzSupport.expression(data, size))
  return 0
}

/// The entry point SwiftPM links as `main`: runs libFuzzer's driver.
@_cdecl("cel_fuzz_evaluator_main")
public func entry(_ argc: CInt, _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> CInt {
  var argc = argc
  var argv = argv
  return LLVMFuzzerRunDriver(&argc, &argv, fuzz)
}

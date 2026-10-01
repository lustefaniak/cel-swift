// libFuzzer target: parse, check, plan and evaluate against the fuzz environment, in checked mode
// and (when checking fails) parse-only mode, with a runtime cost limit and an interrupt deadline so
// every legitimate input terminates quickly. Not a ported file; see Fuzz/README.md.

import CEL
import CELFuzzSupport

/// Far above what a short expression over the fuzz bindings needs, low enough to stop runaway
/// comprehensions within the libFuzzer timeout.
private let costLimit: UInt64 = 1_000_000
/// Wall-clock budget per evaluation, checked every 64 comprehension iterations.
private let deadline: Duration = .seconds(2)

private let programOptions: [ProgramOptions] = [
  ProgramOptions(costLimit: costLimit, interruptCheckFrequency: 64),
  ProgramOptions(evalOptions: [.exhaustiveEval, .optimize], costLimit: costLimit, interruptCheckFrequency: 64),
]

@_cdecl("LLVMFuzzerTestOneInput")
public func fuzz(_ data: UnsafePointer<UInt8>?, _ size: Int) -> CInt {
  let env = FuzzSupport.environment
  let text = FuzzSupport.expression(data, size)
  guard let parsed = try? env.parse(text, description: "<fuzz>") else {
    return 0
  }
  let ast = (try? env.check(parsed, source: TextSource(text, description: "<fuzz>"))) ?? parsed
  for options in programOptions {
    guard let program = try? env.program(ast, options: options) else {
      continue
    }
    let clock = ContinuousClock()
    let end = clock.now.advanced(by: deadline)
    let result = program.eval(MapActivation(FuzzSupport.bindings), interrupt: { clock.now >= end })
    _ = result.value.description
  }
  return 0
}

/// The entry point SwiftPM links as `main`.
@_cdecl("cel_fuzz_eval_main")
public func entry(_ argc: CInt, _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> CInt {
  FuzzSupport.runDriver(argc, argv, fuzz)
}

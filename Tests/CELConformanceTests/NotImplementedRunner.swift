// The runner used by the conformance suite. Replace this file with the real CEL runner (parse, check,
// evaluate, convert values) once the library can run expressions; nothing else in the harness changes.

/// The runner every conformance test goes through.
let conformanceRunner: any ConformanceRunner = NotImplementedRunner()

/// Reports every test as not implemented.
struct NotImplementedRunner: ConformanceRunner {
  var name: String { "not-implemented" }

  func run(_ request: ConformanceRequest) -> ConformanceOutcome {
    .notImplemented("no CEL runner is wired into the conformance harness yet")
  }
}

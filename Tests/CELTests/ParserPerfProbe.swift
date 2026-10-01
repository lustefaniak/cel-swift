import Foundation
import Testing

@testable import CEL

/// Prints parse timings when `CEL_PERF` is set (run with `swift test -c release -Xswiftc -enable-testing`).
@Test func parserPerfProbe() throws {
  guard ProcessInfo.processInfo.environment["CEL_PERF"] != nil else { return }
  let p = try Parser(.macros(Macro.allMacros))
  let exprs = [
    "a.b.c + 1 > 2 && x", "[1, 2, 3].exists(i, i % 2 == 1) || m['k'].size() < 10",
    "request.auth.claims.group == 'admin' ? foo(bar, 1.5, \"s\") : {1: 2}.a",
  ]
  for e in exprs {
    let n = ProcessInfo.processInfo.environment["CEL_PERF_N"].flatMap { Int($0) } ?? 1000
    let start = Date()
    for _ in 0..<n { _ = p.parse(TextSource(e)) }
    print("PERF", e, Date().timeIntervalSince(start) * 1_000_000 / Double(n), "us/parse")
  }
}

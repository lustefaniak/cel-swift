import Testing

@testable import CEL

/// The prediction DFA cache is shared between parses (perf/shared-parser-cache prototype): parses
/// running concurrently must give the same trees and errors as parses run one at a time.
@Test func concurrentParsesMatchSequentialParses() async throws {
  let exprs = [
    "a.b.c + 1 > 2 && x", "[1, 2, 3].exists(i, i % 2 == 1) || m['k'].size() < 10",
    "request.auth.claims.group == 'admin' ? foo(bar, 1.5, \"s\") : {1: 2}.a",
    "!pr.draft && pr.additions + pr.deletions <= 400 && review.risk in ['low', 'medium']",
    "xs.map(x, x * 2).filter(y, y % 3 == 0).map(z, z + 1).size() > 0",
    "a.?b[?0].c.orValue(1)", "has(a.b) && !has(c.d.e)", "-(-x) - --y", "1 + ", "a.b(", "{'a': 1,,}",
    "x == 1 || x == 2 || x == 3 || x == 4 || x == 5 || x == 6 || x == 7 || x == 8",
    "TestAllTypes{single_int64: 1, repeated_int32: [1, 2]}", "b'\\x00' + b'abc'", "1u + 2.5e3 - 0x1F",
    "`a.b`.c", "a ? b ? c : d : e", "(((((((((x)))))))))", "f(g(h(i(j(k)))))", "'\\u00e9' + \"\\U0001F600\"",
  ]
  func render(_ expr: String) throws -> String {
    let parser = try Parser(.macros(Macro.allMacros), .enableOptionalSyntax(true), .enableIdentEscapeSyntax(true))
    let (ast, errors) = parser.parse(TextSource(expr))
    if !errors.isEmpty {
      return errors.toDisplayString()
    }
    return ExprDebug.toDebugStringWithIDs(ast.expr)
  }
  let expected = try exprs.map(render)
  let mismatches = try await withThrowingTaskGroup(of: Int.self) { group in
    for task in 0..<16 {
      group.addTask {
        // Each task walks the expressions in its own order so the parses interleave differently.
        var mismatches = 0
        for i in 0..<(exprs.count * 20) {
          let index = (i * 7 + task) % exprs.count
          if try render(exprs[index]) != expected[index] {
            mismatches += 1
          }
        }
        return mismatches
      }
    }
    return try await group.reduce(0, +)
  }
  #expect(mismatches == 0)
  #expect(try exprs.map(render) == expected)
}

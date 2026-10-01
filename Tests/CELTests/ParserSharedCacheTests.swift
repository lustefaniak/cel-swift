// The ANTLR prediction cache is shared by every parse of a parser (and of its copies) and is used from
// many threads at once: parses running concurrently on a shared cache must give exactly the trees,
// offsets, macro calls and errors that cel-go gives, and that a parse with a cold cache gives.

import Testing

@testable import CEL

private let conformanceRecords = ParserFixtures.load("parse_conformance.json", as: [ParseRecord].self)
private let fuzzRecords = ParserFixtures.load("parse_fuzz.json", as: [ParseRecord].self)

@Suite struct ParserSharedCacheTests {
  /// Every fixture record, parsed from 8 tasks at once through three parsers that start cold and
  /// share their caches between the tasks; each task walks the records in its own order so the DFAs
  /// are built in different interleavings.
  @Test func concurrentParsesOnColdSharedCachesMatchCelGo() async throws {
    let records = conformanceRecords + fuzzRecords
    let parsers = try (0...2).map { try ParseRecord.makeParser(config: $0) }
    let failures = try await withThrowingTaskGroup(of: [String].self) { group in
      for task in 0..<8 {
        group.addTask {
          var failures: [String] = []
          // A stride coprime to the record count visits every record once, from a different start
          // and in a different order in each task.
          let stride = Self.coprimeStride(records.count, task)
          for i in 0..<records.count {
            let record = records[(task * 97 + i * stride) % records.count]
            if let diff = try record.mismatch(using: parsers[min(record.config, 2)]) {
              failures.append("task \(task), \(record): \(diff)")
            }
          }
          return failures
        }
      }
      return try await group.reduce(into: []) { $0 += $1 }
    }
    #expect(records.count > 3000)
    #expect(failures.isEmpty, "\(failures.count) mismatches:\n\(failures.prefix(5).joined(separator: "\n\n"))")
  }

  /// Many short parses of the same few expressions from 16 tasks, against the result of a parse with
  /// a cold cache: the case where tasks contend most on the same DFA states and edges.
  @Test func concurrentParsesMatchColdCacheParses() async throws {
    let exprs = [
      "a.b.c + 1 > 2 && x", "[1, 2, 3].exists(i, i % 2 == 1) || m['k'].size() < 10",
      "request.auth.claims.group == 'admin' ? foo(bar, 1.5, \"s\") : {1: 2}.a",
      "!pr.draft && pr.additions + pr.deletions <= 400 && review.risk in ['low', 'medium']",
      "xs.map(x, x * 2).filter(y, y % 3 == 0).map(z, z + 1).size() > 0",
      "a.?b[?0].c.orValue(1)", "has(a.b) && !has(c.d.e)", "-(-x) - --y", "1 + ", "a.b(", "{'a': 1,,}",
      "x == 1 || x == 2 || x == 3 || x == 4 || x == 5 || x == 6 || x == 7 || x == 8",
      "TestAllTypes{single_int64: 1, repeated_int32: [1, 2]}", "b'\\x00' + b'abc'", "1u + 2.5e3 - 0x1F",
      "`a.b`.c", "a ? b ? c : d : e", "(((((((((x)))))))))", "f(g(h(i(j(k)))))",
      "'\\u00e9' + \"\\U0001F600\"", "a.b.c.d.e.f.g[0][1]['x'].h(1, 2, 3)",
      "x in [1, 2] ? (y < 3 || z >= 4.0) : !w", "1 + + 2", "[1, 2",
    ]
    func makeParser() throws -> Parser {
      try Parser(.macros(Macro.allMacros), .enableOptionalSyntax(true), .enableIdentEscapeSyntax(true))
    }
    @Sendable func render(_ parser: Parser, _ expr: String) -> String {
      let (ast, errors) = parser.parse(TextSource(expr))
      if !errors.isEmpty {
        return errors.toDisplayString()
      }
      return ExprDebug.toDebugStringWithIDs(ast.expr)
    }
    // Each expected result comes from a parser of its own, so from a cold cache.
    let expected = try exprs.map { render(try makeParser(), $0) }
    let shared = try makeParser()
    let mismatches = await withTaskGroup(of: [String].self) { group in
      for task in 0..<16 {
        group.addTask {
          var mismatches: [String] = []
          for i in 0..<(exprs.count * 20) {
            let index = (i * 7 + task) % exprs.count
            let got = render(shared, exprs[index])
            if got != expected[index] {
              mismatches.append("\(exprs[index]): \(got)")
            }
          }
          return mismatches
        }
      }
      return await group.reduce(into: []) { $0 += $1 }
    }
    #expect(mismatches.isEmpty, "\(mismatches.prefix(5))")
    #expect(exprs.map { render(shared, $0) } == expected)
  }

  /// Environments extended from one another share the cache; unrelated environments do not.
  @Test func extendedEnvironmentsSharePredictionCache() throws {
    let base = try Environment()
    let extended = try base.extending(.variable("x", .int))
    #expect(base.parser.predictionCache === extended.parser.predictionCache)
    #expect(try Environment().parser.predictionCache !== base.parser.predictionCache)
  }

  private static func coprimeStride(_ count: Int, _ task: Int) -> Int {
    func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? a : gcd(b, a % b) }
    var stride = 1 + task * 2
    while gcd(stride, count) != 1 {
      stride += 1
    }
    return stride
  }
}

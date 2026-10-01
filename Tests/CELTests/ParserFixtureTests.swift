// Differential tests against cel-go: every expression of the cel-spec simple conformance tests, and
// deterministic mutations of them, parsed by cel-go (tools/parsedump) and by this parser. Debug
// strings with ids, offset ranges, macro calls and error output must match exactly.

import Testing

@testable import CEL

private let conformanceRecords = ParserFixtures.load("parse_conformance.json", as: [ParseRecord].self)
private let fuzzRecords = ParserFixtures.load("parse_fuzz.json", as: [ParseRecord].self)

@Suite struct ParserFixtureTests {
  @Test func conformanceExpressionsMatchCelGo() throws {
    var failures: [String] = []
    for record in conformanceRecords {
      if let diff = try record.mismatch() {
        failures.append("\(record) (\(record.expr)): \(diff)")
      }
    }
    #expect(conformanceRecords.count > 2000)
    #expect(failures.isEmpty, "\(failures.count) mismatches:\n\(failures.prefix(10).joined(separator: "\n\n"))")
  }

  @Test func fuzzedExpressionsMatchCelGo() throws {
    var failures: [String] = []
    for record in fuzzRecords {
      if let diff = try record.mismatch() {
        failures.append("\(record.expr.debugDescription): \(diff)")
      }
    }
    #expect(fuzzRecords.count > 1000)
    #expect(failures.isEmpty, "\(failures.count) mismatches:\n\(failures.prefix(10).joined(separator: "\n\n"))")
  }
}

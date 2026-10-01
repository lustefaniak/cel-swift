// Static estimate and runtime cost of the cost tables of cel-go's ext/*_test.go (TestListsCosts,
// TestSets, TestRegexCosts, TestEncodersCosts, TestMathCosts, TestBindings,
// TestTwoVarComprehensionsCost, TestStringCostTracking), extracted into Resources/cost-tables.jsonl by
// tools/ext-fixtures/extract_cost_tables.py, which also checks every row against tools/oracle.
//
// Each row runs as cel-go's testCheckCost / testEvalWithCost do: parse, check, estimate with the size
// hints (each `[0, hint]`), then evaluate the parsed and the checked expression to `true`, with the
// runtime cost compared for the checked one.

import Foundation
import Testing

@testable import CEL
@testable import CELExtensions

struct CostTableRow: Sendable, CustomStringConvertible {
  let entry: String
  let test: String
  let env: String
  let version: UInt32?
  let expr: String
  let container: String?
  let vars: [String: String]
  let inputs: [String: String]
  let hints: [String: UInt64]
  let estimate: ClosedRange<UInt64>
  let actual: UInt64

  var description: String { "\(entry) \(expr)" }
}

enum CostTables {
  static let rows: [CostTableRow] = {
    guard let url = Bundle.module.url(forResource: "cost-tables", withExtension: "jsonl", subdirectory: "Resources"),
      let text = try? String(contentsOf: url, encoding: .utf8)
    else { return [] }
    return text.split(separator: "\n").compactMap { line in
      guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
        let estimate = obj["estimate"] as? [String], estimate.count == 2,
        let low = UInt64(estimate[0]), let high = UInt64(estimate[1]),
        let actual = (obj["actual"] as? String).flatMap({ UInt64($0) })
      else { return nil }
      return CostTableRow(
        entry: obj["entry"] as? String ?? "", test: obj["test"] as? String ?? "", env: obj["env"] as? String ?? "",
        version: (obj["version"] as? Int).map { UInt32($0) }, expr: obj["expr"] as? String ?? "",
        container: obj["container"] as? String,
        vars: obj["vars"] as? [String: String] ?? [:], inputs: obj["in"] as? [String: String] ?? [:],
        hints: (obj["hints"] as? [String: Int] ?? [:]).mapValues { UInt64($0) },
        estimate: low...high, actual: actual)
    }
  }()

  /// The libraries and options of each cel-go test's environment.
  static func options(_ row: CostTableRow) -> [Environment.Option] {
    let v = row.version ?? Library.latestVersion
    var options: [Environment.Option] = []
    switch row.env {
    case "lists": options += [.library(.lists(version: v))]
    case "sets": options += [.library(.sets(version: v)), .macroCallTracking]
    case "regex": options += [.optionalTypes, .library(.regex(version: v))]
    case "encoders": options += [.library(.encoders(version: v)), .macroCallTracking]
    case "math": options += [.library(.math(version: v)), .macroCallTracking]
    case "bindings": options += [.library(.bindings(version: 0)), .library(.strings)]
    case "comprehensions":
      options += [
        .library(.twoVarComprehensions), .library(.bindings), .library(.lists), .library(.strings), .optionalTypes,
        .macroCallTracking, .hiddenAccumulatorName(true),
      ]
    case "strings-v5": options += [.library(.strings(version: 5))]
    default: Issue.record("unknown environment \(row.env)")
    }
    if let container = row.container {
      options.append(.container(container))
    }
    return options
  }
}

/// Parses a CEL type name as the extractor writes it: `int`, `list(int)`, `map(string, list(int))`.
func parseTypeName(_ text: Substring) throws -> CELType {
  let text = text.trimmingCharacters(in: .whitespaces)
  guard let open = text.firstIndex(of: "("), text.hasSuffix(")") else {
    switch text {
    case "int": return .int
    case "uint": return .uint
    case "double": return .double
    case "bool": return .bool
    case "string": return .string
    case "bytes": return .bytes
    case "dyn": return .dyn
    case "null_type": return .null
    case "google.protobuf.Duration": return .duration
    case "google.protobuf.Timestamp": return .timestamp
    default: throw DeclarationError("unknown type \(text)")
    }
  }
  let name = text[..<open]
  let inner = text[text.index(after: open)..<text.index(before: text.endIndex)]
  var params: [Substring] = []
  var depth = 0
  var start = inner.startIndex
  for i in inner.indices {
    switch inner[i] {
    case "(": depth += 1
    case ")": depth -= 1
    case "," where depth == 0:
      params.append(inner[start..<i])
      start = inner.index(after: i)
    default: break
    }
  }
  params.append(inner[start...])
  switch (name, params.count) {
  case ("list", 1): return .list(try parseTypeName(params[0]))
  case ("map", 2): return .map(key: try parseTypeName(params[0]), value: try parseTypeName(params[1]))
  default: throw DeclarationError("unknown type \(text)")
  }
}

struct CostTableTests {
  @Test(arguments: CostTables.rows)
  func row(_ row: CostTableRow) throws {
    var options = CostTables.options(row)
    let base = try Environment(options: options)
    var variables: [String: Value] = [:]
    for (name, literal) in row.inputs {
      variables[name] = try base.program(try base.compile(literal)).evaluate().value
    }
    for (name, type) in row.vars {
      options.append(.variable(name, try parseTypeName(type[...])))
    }
    let env = try Environment(options: options)
    let parsed = try env.parse(row.expr)
    let checked = try env.check(parsed)

    let hints = row.hints.mapValues { 0...$0 }
    #expect(env.estimateCost(checked, sizeHints: hints) == row.estimate, "estimate of \(row)")

    let result = try env.program(checked, options: [.trackCost]).evaluate(variables)
    if row.test != "TestStringCostTracking" {
      #expect(result.value == .bool(true), "\(row)")
    }
    #expect(result.cost == row.actual, "runtime cost of \(row)")
    if row.test != "TestStringCostTracking" {
      #expect(try env.program(parsed).evaluate(variables).value == .bool(true), "parse-only \(row)")
    }
  }

  @Test func tablesLoaded() {
    #expect(CostTables.rows.count == 158)
  }
}

// End-to-end runs of the expression tables of cel-go's ext/*_test.go, extracted into
// Resources/go-tables.jsonl by tools/ext-fixtures/extract_go_tables.py. Each row names the
// environment and the harness of the cel-go test it comes from.

import Foundation
import Testing

@testable import CEL
@testable import CELExtensions

struct GoTableRow: Sendable, CustomStringConvertible {
  let entry: String
  let env: String
  let kind: String
  let fields: [String: String]
  let flags: [String: Bool]
  /// Fields holding Go expressions the harness cannot use.
  let goFields: [String]
  /// `expectedRuntimeCost`, when the row has one other than 0 (cel-go then checks costs).
  var runtimeCost: UInt64? = nil
  /// `expectedEstimatedCost`.
  var estimatedCost: ClosedRange<UInt64>? = nil

  var description: String { entry }
}

enum GoTables {
  /// Go-valued fields the harness reads itself.
  static let costGoFields: Set<String> = ["expectedRuntimeCost", "expectedEstimatedCost"]

  /// The numbers of a Go `checker.CostEstimate{Min: a, Max: b}` or `checker.FixedCostEstimate(a)`.
  static func costEstimate(_ go: String) -> ClosedRange<UInt64>? {
    let numbers = go.split(whereSeparator: { !$0.isNumber }).compactMap { UInt64($0) }
    switch numbers.count {
    case 1: return numbers[0]...numbers[0]
    case 2 where numbers[0] <= numbers[1]: return numbers[0]...numbers[1]
    default: return nil
    }
  }

  static let rows: [GoTableRow] = {
    guard let url = Bundle.module.url(forResource: "go-tables", withExtension: "jsonl", subdirectory: "Resources"),
      let text = try? String(contentsOf: url, encoding: .utf8)
    else { return [] }
    var rows: [GoTableRow] = []
    for line in text.split(separator: "\n") {
      guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
        let fields = obj["fields"] as? [String: Any]
      else { continue }
      var strings: [String: String] = [:]
      var flags: [String: Bool] = [:]
      var goFields: [String] = []
      var costs: [String: String] = [:]
      for (k, v) in fields {
        if let s = v as? String {
          strings[k] = s
        } else if let b = v as? Bool {
          flags[k] = b
        } else if costGoFields.contains(k), let go = (v as? [String: Any])?["go"] as? String {
          costs[k] = go
        } else {
          goFields.append(k)
        }
      }
      var row = GoTableRow(
        entry: obj["entry"] as? String ?? "", env: obj["env"] as? String ?? "",
        kind: obj["kind"] as? String ?? "", fields: strings, flags: flags, goFields: goFields)
      if let runtime = costs["expectedRuntimeCost"].flatMap({ UInt64($0) }), runtime != 0 {
        row.runtimeCost = runtime
        row.estimatedCost = costs["expectedEstimatedCost"].flatMap(costEstimate)
      }
      rows.append(row)
    }
    return rows
  }()

  /// The rows without Go-valued fields: the ones the harness can run. A stored property rather than
  /// a closure in `@Test(arguments:)`, which crashes the Swift 6.0 compiler.
  static let runnableRows: [GoTableRow] = rows.filter { $0.goFields.isEmpty }

  static func environment(_ name: String) throws -> Environment {
    switch name {
    case "strings": return try Environment(.standardLibrary, .library(.strings))
    case "strings-v3": return try Environment(.standardLibrary, .library(.strings(version: 3)))
    case "math": return try Environment(.standardLibrary, .library(.math), .macroCallTracking)
    case "lists": return try Environment(.standardLibrary, .library(.lists))
    case "lists-v1": return try Environment(.standardLibrary, .library(.lists(version: 1)))
    case "encoders": return try Environment(.standardLibrary, .library(.encoders))
    case "comprehensions":
      // cel-go testCompreEnv.
      return try Environment(
        .standardLibrary, .library(.twoVarComprehensions), .library(.bindings), .library(.lists),
        .library(.strings), .optionalTypes, .macroCallTracking, .hiddenAccumulatorName(true))
    case "regex": return try Environment(.standardLibrary, .optionalTypes, .library(.regex))
    default: throw DeclarationError("unknown environment \(name)")
    }
  }
}

/// Rows the port does not run, with the reason.
private let unsupported: [String: String] = {
  let nativeTypes = "uses ext.TestAllTypes, a Go struct exposed with ext.NativeTypes (Go reflection, not ported)"
  let exampleType = "uses google.expr.proto2.test.ExampleType, a cel-go test proto the port does not generate"
  var map: [String: String] = ["lists_test.go:68": exampleType, "lists_test.go:76": exampleType]
  for line in [714, 721, 728, 809, 815] {
    map["formatting_test.go:\(line)"] = nativeTypes
  }
  for line in [728, 735, 742, 823, 829] {
    map["formatting_v2_test.go:\(line)"] = nativeTypes
  }
  return map
}()

/// Rows whose cel-go expectation is replaced by the spec's, with the error the port reports instead
/// (docs/divergences.md).
private let specErrors: [String: String] = [
  // String offsets past the end: cel-go returns -1 (or the length for ''), the spec an error.
  "strings_test.go:148": "index out of range: 30",
  "strings_test.go:150": "index out of range: 30",
  "strings_test.go:159": "index out of range: 30",
  "strings_test.go:161": "index out of range: 30",
]

struct GoTableTests {
  /// The format tables carry cel-go's cost expectations; make sure the harness reads them.
  @Test func costExpectationsLoaded() {
    let withCosts = GoTables.runnableRows.filter { $0.runtimeCost != nil }
    #expect(withCosts.count == 99)
    #expect(withCosts.allSatisfy { $0.estimatedCost != nil })
  }

  @Test(arguments: GoTables.runnableRows)
  func row(_ row: GoTableRow) throws {
    if let reason = unsupported[row.entry] {
      withKnownIssue(Comment(rawValue: reason)) { Issue.record("\(row.entry)") }
      return
    }
    if let locale = row.fields["locale"], locale != "en_US" {
      withKnownIssue("locale \(locale): only the en-US symbols of golang.org/x/text are ported", isIntermittent: true) {
        try runRow(row)
      }
      return
    }
    try runRow(row)
  }

  private func runRow(_ row: GoTableRow) throws {
    let env = try GoTables.environment(row.env)
    let err = specErrors[row.entry] ?? row.fields["err"] ?? ""
    let expr: String
    let expected: Value
    if row.kind == "format" {
      expr = "\(GoFormat.quote(row.fields["format"] ?? "")).format([\(row.fields["formatArgs"] ?? "")])"
      expected = .string(row.fields["expectedOutput"] ?? "")
    } else {
      expr = row.fields["expr"] ?? ""
      expected = .bool(true)
    }
    let parseOnly = row.flags["parseOnly"] == true || row.flags["skipCompileCheck"] == true
    let parsed: ParsedExpression
    do {
      parsed = try env.parse(expr)
    } catch {
      #expect(!err.isEmpty && "\(error)".contains(err), "\(row.entry) \(expr): parse error \(error)")
      return
    }
    var programs: [Program] = []
    if row.kind == "format" || !parseOnly {
      if !parseOnly {
        do {
          let checked = try env.check(parsed)
          if let estimate = row.estimatedCost {
            #expect(env.estimateCost(checked) == estimate, "\(row.entry) \(expr): estimated cost")
          }
          programs.append(try env.program(checked, options: row.runtimeCost == nil ? [] : [.trackCost]))
        } catch {
          #expect(
            !err.isEmpty && "\(error)".contains(err) && row.kind != "runtime",
            "\(row.entry) \(expr): compile error \(error)")
          return
        }
        #expect(row.kind != "static", "\(row.entry) \(expr): compiled, want error \(err)")
        if row.kind == "static" {
          return
        }
      }
    }
    if row.kind != "format" || parseOnly {
      programs.append(try env.program(parsed))
    }
    for program in programs {
      do {
        let result = try program.evaluate()
        #expect(err.isEmpty, "\(row.entry) \(expr): got \(result.value), want error \(err)")
        if let cost = result.cost, let want = row.runtimeCost {
          #expect(cost == want, "\(row.entry) \(expr): runtime cost")
        }
        if err.isEmpty {
          #expect(result.value == expected, "\(row.entry) \(expr): got \(result.value), want \(expected)")
        }
      } catch {
        #expect(!err.isEmpty && error.message.contains(err), "\(row.entry) \(expr): eval error \(error.message)")
      }
    }
  }
}

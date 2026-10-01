// Partial evaluation against cel-go: PartialFixtures/partial_eval.json (generated with
// tools/partial-fixtures from cel-go through the oracle) records cel-go's result, unknown set and
// `Env.ResidualAst` for expressions with unknown attributes, in checked and parse-only mode. Each case
// is replayed through the public API: `Program.Option.partialEvaluation` + `.trackState`, then
// `Environment.residual(of:state:)`.

import Foundation
import Testing

@testable import CEL

struct PartialFixture: Sendable, CustomTestStringConvertible {
  var id: String
  var expr: String
  var checked: Bool
  var variables: [(String, CELType)]
  var bindings: [String: Value]
  var unknowns: [UnknownPattern]
  /// The expected value, error message or unknown set (expression id to attribute trails).
  var value: Value?
  var error: String?
  var unknown: [Int64: [String]]?
  var residual: String?
  var residualError: String?

  var testDescription: String { "\(id): \(expr)" }
}

private struct PartialFixtureError: Error, CustomStringConvertible {
  var description: String
}

/// Parses the generator's type syntax: `int`, `list(int)`, `map(string, dyn)`, `optional(int)`.
private func parseType(_ text: String) throws -> CELType {
  let t = text.trimmingCharacters(in: .whitespaces)
  guard let open = t.firstIndex(of: "("), t.hasSuffix(")") else {
    switch t {
    case "int": return .int
    case "uint": return .uint
    case "double": return .double
    case "bool": return .bool
    case "string": return .string
    case "bytes": return .bytes
    case "dyn": return .dyn
    case "timestamp": return .timestamp
    case "duration": return .duration
    default: throw PartialFixtureError(description: "unknown type \(t)")
    }
  }
  let name = String(t[..<open])
  let inner = t[t.index(after: open)..<t.index(before: t.endIndex)]
  var params: [String] = []
  var depth = 0
  var current = ""
  for c in inner {
    if c == "," && depth == 0 {
      params.append(current)
      current = ""
      continue
    }
    if c == "(" { depth += 1 }
    if c == ")" { depth -= 1 }
    current.append(c)
  }
  params.append(current)
  let types = try params.map(parseType)
  switch (name, types.count) {
  case ("list", 1): return .list(types[0])
  case ("map", 2): return .map(key: types[0], value: types[1])
  case ("optional", 1): return .optional(types[0])
  default: throw PartialFixtureError(description: "unknown type \(t)")
  }
}

/// Decodes the oracle's value encoding (tools/oracle/README.md) for the kinds the fixtures use.
private func decodeValue(_ json: Any) throws -> Value {
  guard let object = json as? [String: Any], object.count == 1, let (kind, payload) = object.first else {
    throw PartialFixtureError(description: "bad value \(json)")
  }
  switch kind {
  case "null": return .null
  case "bool": return .bool(try cast(payload))
  case "int": return .int(try parseNumber(payload))
  case "uint": return .uint(try parseNumber(payload))
  case "double": return .double(try cast(payload))
  case "string": return .string(try cast(payload))
  case "list":
    let items: [Any] = try cast(payload)
    return .list(ArrayList(try items.map(decodeValue)))
  case "map":
    let entries: [[String: Any]] = try cast(payload)
    var map = OrderedMap()
    for entry in entries {
      let key: MapKey
      switch try decodeValue(entry["key"] as Any) {
      case .string(let s): key = .string(s)
      case .int(let i): key = .int(i)
      case .uint(let u): key = .uint(u)
      case .bool(let b): key = .bool(b)
      default: throw PartialFixtureError(description: "bad map key \(entry)")
      }
      map[key] = try decodeValue(entry["value"] as Any)
    }
    return .map(map)
  case "optional":
    if payload is NSNull {
      return .optional(nil)
    }
    return .optional(try decodeValue(payload))
  case "timestamp":
    return Value.string(try cast(payload)).convert(to: .timestamp)
  case "duration":
    return Value.string(try cast(payload)).convert(to: .duration)
  default:
    throw PartialFixtureError(description: "unsupported value kind \(kind)")
  }
}

private func cast<T>(_ value: Any) throws -> T {
  guard let v = value as? T else {
    throw PartialFixtureError(description: "expected \(T.self), got \(value)")
  }
  return v
}

private func parseNumber<T: FixedWidthInteger>(_ value: Any) throws -> T {
  if let s = value as? String, let n = T(s) {
    return n
  }
  if let n = value as? NSNumber, let v = T(exactly: n.int64Value) {
    return v
  }
  throw PartialFixtureError(description: "bad integer \(value)")
}

private func decodePattern(_ json: [String: Any]) throws -> UnknownPattern {
  var pattern = UnknownPattern(try cast(json["variable"] as Any))
  for q in (json["path"] as? [Any]) ?? [] {
    if let s = q as? String, s == "*" {
      pattern = pattern.wildcard()
      continue
    }
    switch try decodeValue(q) {
    case .string(let s): pattern = pattern.qualified(by: .string(s))
    case .int(let i): pattern = pattern.qualified(by: .int(i))
    case .uint(let u): pattern = pattern.qualified(by: .uint(u))
    case .bool(let b): pattern = pattern.qualified(by: .bool(b))
    default: throw PartialFixtureError(description: "bad qualifier \(q)")
    }
  }
  return pattern
}

let partialFixtures: [PartialFixture] = {
  do {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .appendingPathComponent("PartialFixtures/partial_eval.json")
    let records: [[String: Any]] = try cast(try JSONSerialization.jsonObject(with: Data(contentsOf: url)))
    return try records.map { r in
      let result: [String: Any] = try cast(r["result"] as Any)
      var fixture = PartialFixture(
        id: try cast(r["id"] as Any), expr: try cast(r["expr"] as Any), checked: try cast(r["checked"] as Any),
        variables: try (r["variables"] as? [[String]] ?? []).map { ($0[0], try parseType($0[1])) },
        bindings: try (r["bindings"] as? [String: Any] ?? [:]).mapValues(decodeValue),
        unknowns: try (r["unknowns"] as? [[String: Any]] ?? []).map(decodePattern),
        residual: r["residual"] as? String, residualError: r["residual_error"] as? String)
      if let value = result["value"] {
        fixture.value = try decodeValue(value)
      } else if let error = result["error"] as? String {
        fixture.error = error
      } else {
        let attributes = result["unknown_attributes"] as? [String: [String]] ?? [:]
        var unknown: [Int64: [String]] = [:]
        for (id, trails) in attributes {
          guard let id = Int64(id) else { throw PartialFixtureError(description: "bad id \(id)") }
          unknown[id] = trails
        }
        fixture.unknown = unknown
      }
      return fixture
    }
  } catch {
    fatalError("cannot load PartialFixtures/partial_eval.json: \(error)")
  }
}()

struct PartialEvaluationFixtureTests {
  @Test(arguments: partialFixtures)
  func partialEvaluation(_ tc: PartialFixture) throws {
    let env = try Environment(
      .optionalTypes, .macroCallTracking, .variables(tc.variables.map { VariableDecl(name: $0.0, type: $0.1) }))
    let options: [Program.Option] = [.partialEvaluation, .trackState, .errorsAsValues]
    let variables = Variables(tc.bindings, unknowns: tc.unknowns)
    let state: EvaluationState
    let residual: String
    if tc.checked {
      let checked = try env.compile(tc.expr)
      let result = try env.program(checked, options: options).evaluate(variables)
      try verify(tc, result.value)
      state = try #require(result.state)
      residual = try env.residual(of: checked, state: state).description
    } else {
      let parsed = try env.parse(tc.expr)
      let result = try env.program(parsed, options: options).evaluate(variables)
      try verify(tc, result.value)
      state = try #require(result.state)
      residual = try env.residual(of: parsed, state: state).description
    }
    #expect(tc.residualError == nil, "cel-go residual error: \(tc.residualError ?? "")")
    #expect(residual == tc.residual)
  }

  private func verify(_ tc: PartialFixture, _ got: Value) throws {
    if let want = tc.value {
      #expect(got == want, "got \(got), want \(want)")
    } else if let error = tc.error {
      #expect(got.asError?.message == error, "got \(got), want error \(error)")
    } else if let unknown = tc.unknown {
      let set = try #require(got.asUnknown, "got \(got), want unknown \(unknown)")
      var trails: [Int64: [String]] = [:]
      for id in set.exprIDs {
        trails[id] = (set.attributeTrails(forExprID: id) ?? []).map(\.description)
      }
      #expect(trails == unknown, "got \(set)")
    }
  }
}

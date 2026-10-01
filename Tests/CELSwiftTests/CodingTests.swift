// CELEncoder and CELDecoder: Swift values to CEL values and back, through expressions.

import CEL
import CELSwift
import Foundation
import Testing

private struct Scalars: Codable, Equatable {
  var bool: Bool
  var string: String
  var int: Int
  var int8: Int8
  var int32: Int32
  var int64: Int64
  var uint: UInt
  var uint16: UInt16
  var uint64: UInt64
  var double: Double
  var float: Float
}

private struct Leaves: Codable, Equatable {
  var date: Date
  var duration: Duration
  var data: Data
  var url: URL
  var id: UUID
}

private struct Collections: Codable, Equatable {
  var list: [Int]
  var set: Set<String>
  var byName: [String: Double]
  var byNumber: [Int: String]
  var numericStrings: [String: Int]
  var nested: [[String: [Bool]]]
}

struct CodingTests {
  @Test func scalarsKeepTheirCELTypes() throws {
    let value = Scalars(
      bool: true, string: "zażółć", int: -1, int8: -8, int32: 32, int64: .min, uint: 1, uint16: 16, uint64: .max,
      double: 1.5, float: 0.25)
    let encoded = try CELEncoder().encode(value)
    let object = try #require(encoded.asObject)
    #expect(object.field("bool") == true)
    #expect(object.field("string") == "zażółć")
    #expect(object.field("int") == .int(-1))
    #expect(object.field("int8") == .int(-8))
    #expect(object.field("int64") == .int(.min))
    #expect(object.field("uint") == .uint(1))
    #expect(object.field("uint64") == .uint(.max))
    #expect(object.field("double") == .double(1.5))
    #expect(object.field("float") == .double(0.25))
    #expect(try CELDecoder().decode(Scalars.self, from: encoded) == value)
  }

  @Test func leavesUseNativeCELTypes() throws {
    let value = Leaves(
      date: Date(timeIntervalSince1970: 1_790_000_000.123456), duration: .milliseconds(1500),
      data: Data([0, 1, 255]), url: try #require(URL(string: "https://example.com/a?b=c")),
      id: try #require(UUID(uuidString: "6BA7B810-9DAD-11D1-80B4-00C04FD430C8")))
    let encoded = try CELEncoder().encode(value)
    let object = try #require(encoded.asObject)
    #expect(object.field("date").asTimestamp == CELTimestamp(secondsSinceEpoch: 1_790_000_000, nanoseconds: 123_456_001))
    #expect(object.field("duration") == .duration(CELDuration(nanoseconds: 1_500_000_000)))
    #expect(object.field("data") == .bytes([0, 1, 255]))
    #expect(object.field("url") == "https://example.com/a?b=c")
    #expect(object.field("id") == "6BA7B810-9DAD-11D1-80B4-00C04FD430C8")
    let decoded = try CELDecoder().decode(Leaves.self, from: encoded)
    #expect(abs(decoded.date.timeIntervalSince(value.date)) < 1e-6)
    #expect(decoded.duration == value.duration)
    #expect(decoded.data == value.data)
    #expect(decoded.url == value.url)
    #expect(decoded.id == value.id)
  }

  @Test func collections() throws {
    let value = Collections(
      list: [3, 1, 2], set: ["only"], byName: ["a": 1.5], byNumber: [7: "seven"], numericStrings: ["1": 1],
      nested: [["x": [true, false]]])
    let encoded = try CELEncoder().encode(value)
    let object = try #require(encoded.asObject)
    #expect(object.field("list") == [3, 1, 2])
    #expect(object.field("set") == ["only"])
    #expect(object.field("byName").asMap == [.string("a"): .double(1.5)])
    #expect(object.field("byNumber").asMap == [.int(7): .string("seven")])
    // String keys that look like numbers stay strings.
    #expect(object.field("numericStrings").asMap == [.string("1"): .int(1)])
    #expect(try CELDecoder().decode(Collections.self, from: encoded) == value)
  }

  @Test func optionalsAreNullAndUnset() throws {
    let pr = ChangeRequest.sample
    let encoded = try Value(encoding: pr)
    let object = try #require(encoded.asObject)
    #expect(object.field("reviewer") == .null)
    #expect(object.isFieldSet("reviewer") == false)
    #expect(object.isFieldSet("repo") == true)
    #expect(object.field("nope").asError?.message == "no such field 'nope'")
    #expect(try encoded.decoded(as: ChangeRequest.self) == pr)

    var reviewed = pr
    reviewed.reviewer = "bob"
    #expect(try Value(encoding: reviewed).decoded(as: ChangeRequest.self) == reviewed)
  }

  @Test func structsAreObjectsNamedAfterTheirType() throws {
    let encoded = try CELEncoder().encode(Review.sample)
    #expect(encoded.celType == .object("prbar.Review"))
    let finding = try #require(encoded.asObject?.field("findings").asList?.first)
    #expect(finding.celType == .object("CELSwiftTests.Finding"))
    #expect(finding.asObject?.field("severity") == .int(1))
  }

  @Test func structsAsMaps() throws {
    let options = CELCodingOptions(structRepresentation: .maps)
    let encoded = try CELEncoder(options: options).encode(Selection(rule: "r", action: "a"))
    #expect(encoded.asMap == [.string("rule"): .string("r"), .string("action"): .string("a")])
    #expect(try CELDecoder(options: options).decode(Selection.self, from: encoded) == Selection(rule: "r", action: "a"))
  }

  @Test func snakeCaseKeys() throws {
    let options = CELCodingOptions(keyStrategy: .convertToSnakeCase)
    let encoded = try CELEncoder(options: options).encode(ChangeRequest.sample)
    let object = try #require(encoded.asObject as? any CustomStringConvertible)
    #expect(object.description.contains("base_ref: \"main\""))
    #expect(object.description.contains("created_at: timestamp("))
    #expect(try CELDecoder(options: options).decode(ChangeRequest.self, from: encoded) == .sample)
  }

  @Test(arguments: [
    ("headSha", "head_sha"), ("isDraft", "is_draft"), ("myURLProperty", "my_url_property"), ("ID", "id"),
    ("costUSD", "cost_usd"), ("_private", "_private"), ("already_snake", "already_snake"), ("a", "a"),
  ])
  func snakeCaseConversion(key: String, field: String) throws {
    struct Probe: Encodable {
      let key: String
      func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: AnyKey.self)
        try container.encode(1, forKey: AnyKey(stringValue: key))
      }
    }
    let encoded = try CELEncoder(options: CELCodingOptions(keyStrategy: .convertToSnakeCase)).encode(Probe(key: key))
    #expect(encoded.asObject?.field(field) == .int(1))
  }

  @Test func variablesFromFacts() throws {
    let variables = try CELEncoder().encodeVariables(SelectFacts.sample)
    #expect(variables.keys.sorted() == ["lists", "pr", "signals", "trigger"])
    #expect(variables["trigger"] == "review_requested")
    #expect(throws: EncodingError.self) {
      _ = try CELEncoder().encodeVariables([1, 2])
    }
  }

  @Test func encodedFactsEvaluate() throws {
    let env = try Environment(.variables(from: SelectFacts.self))
    let program = try env.program(
      env.compile("pr.createdAt < timestamp('2030-01-01T00:00:00Z') && !has(pr.reviewer) && pr.reviewer == null"))
    #expect(try program.evaluate(Variables(encoding: SelectFacts.sample)).value == true)
  }

  @Test func programEvaluatesFactsToSwiftTypes() throws {
    let env = try Environment(.variables(from: SelectFacts.self), .variable("n", .int))
    let program = try env.program(env.compile("pr.additions + pr.deletions"))
    let size: Int = try program.evaluate(SelectFacts.sample)
    #expect(size == 150)
    #expect(try program.evaluate(SelectFacts.sample, as: Double.self) == 150)
    // Dictionary literals still pick the core overload.
    let plain = try env.program(env.compile("n + 1")).evaluate(["n": 1])
    #expect(plain.value == 2)
  }

  @Test func decodesExpressionResults() throws {
    let env = try Environment()
    let value = try env.program(env.compile("{'rule': 'r', 'verdict': 'approve', 'flag': null}"))
      .evaluate().value
    #expect(try value.decoded(as: Decision.self) == Decision(rule: "r", verdict: "approve", flag: nil))
  }

  @Test func decodesOptionalValues() throws {
    #expect(try Value.optional(.int(3)).decoded(as: Int?.self) == 3)
    #expect(try Value.optional(nil).decoded(as: Int?.self) == nil)
    #expect(try Value.optional(.int(3)).decoded(as: Int.self) == 3)
    #expect(try Value.null.decoded(as: String?.self) == nil)
  }

  @Test func numbersConvertWhenTheyFit() throws {
    #expect(try Value.uint(7).decoded(as: Int.self) == 7)
    #expect(try Value.int(7).decoded(as: UInt8.self) == 7)
    #expect(try Value.double(3).decoded(as: Int.self) == 3)
    #expect(try Value.int(2).decoded(as: Double.self) == 2)
    #expect(throws: DecodingError.self) { try Value.int(300).decoded(as: UInt8.self) }
    #expect(throws: DecodingError.self) { try Value.int(-1).decoded(as: UInt.self) }
    #expect(throws: DecodingError.self) { try Value.double(1.5).decoded(as: Int.self) }
  }

  @Test func decodingErrorsNameThePath() throws {
    let value: Value = ["rule": "r", "verdict": 3]
    do {
      _ = try value.decoded(as: Decision.self)
      Issue.record("expected a type mismatch")
    } catch DecodingError.typeMismatch(_, let context) {
      #expect(context.codingPath.map(\.stringValue) == ["verdict"])
      #expect(context.debugDescription == "expected String, found a int value")
    }
    // A do/catch rather than #expect(throws:): Swift 6.0 crashes type-checking that macro expansion.
    let partial = Value(["rule": "r"] as [String: Value])
    do {
      _ = try partial.decoded(as: Decision.self)
      Issue.record("expected a missing key")
    } catch DecodingError.keyNotFound(let key, _) {
      #expect(key.stringValue == "verdict")
    }
  }

  @Test func errorAndUnknownValuesDoNotDecode() {
    #expect(throws: DecodingError.self) { try Value.error(EvalError("boom")).decoded(as: Int.self) }
    #expect(throws: DecodingError.self) {
      try Value.unknown(UnknownSet(expressionID: 1)).decoded(as: Int.self)
    }
  }

  @Test func datesOutsideTheTimestampRangeFailToEncode() {
    #expect(throws: EncodingError.self) {
      _ = try CELEncoder().encode(Date(timeIntervalSince1970: 1e12))
    }
  }

  @Test func customRepresentation() throws {
    #expect(try CELEncoder().encode(Severity.warning) == .int(2))
    #expect(try CELDecoder().decode(Severity.self, from: .int(3)) == .blocker)
    #expect(throws: DecodingError.self) { try CELDecoder().decode(Severity.self, from: .int(9)) }
  }

  @Test func rawValueEnumsEncodeTheirRawValue() throws {
    #expect(try CELEncoder().encode(Verdict.requestChanges) == "request_changes")
    #expect(try CELDecoder().decode(Verdict.self, from: "request_changes") == .requestChanges)
  }
}

private struct AnyKey: CodingKey {
  var stringValue: String
  var intValue: Int? { nil }
  init(stringValue: String) { self.stringValue = stringValue }
  init?(intValue: Int) { nil }
}

// Copyright 2018 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
// Ported from cel-go common/types/{bool,bytes,double,duration,null,string,timestamp,optional,
// unknown}_test.go (the parts without Go/protobuf native conversions).

import Testing

@testable import CEL

private func ts(_ seconds: Int64, _ nanos: Int32 = 0) -> Value {
  .timestamp(CELTimestamp(secondsSinceEpoch: seconds, nanoseconds: nanos))
}

private func dur(_ seconds: Int64, _ nanos: Int64 = 0) -> Value {
  .duration(CELDuration(nanoseconds: seconds &* 1_000_000_000 &+ nanos))
}

struct BoolValueTests {
  @Test func compare() {
    #expect(Value.bool(false).compare(.bool(true)) == .int(-1))
    #expect(Value.bool(true).compare(.bool(false)) == .int(1))
    #expect(Value.bool(true).compare(.bool(true)) == .int(0))
    #expect(Value.bool(true).compare(.int(0)).isError)
  }

  @Test func convertToType() {
    #expect(Value.bool(true).convert(to: .string) == "true")
    #expect(Value.bool(true).convert(to: .bool) == true)
    #expect(Value.bool(true).convert(to: .type(nil)) == .type(.bool))
    #expect(Value.bool(true).convert(to: .timestamp).isError)
  }

  @Test func equalAndZero() {
    #expect(Value.bool(true).celEquals(.bool(true)) == true)
    #expect(Value.bool(false).celEquals(.bool(true)) == false)
    #expect(Value.bool(false).celEquals(.int(0)) == false)
    #expect(Value.bool(false).isZeroValue)
    #expect(Value.bool(true).isZeroValue == false)
    #expect(Value.bool(true).negate() == false)
  }
}

struct BytesValueTests {
  @Test func add() {
    #expect(Value.bytes(Array("hello".utf8)).add(.bytes(Array("world".utf8))) == .bytes(Array("helloworld".utf8)))
    #expect(Value.bytes(Array("hello".utf8)).add(.string("world")).isError)
  }

  @Test func compare() {
    #expect(Value.bytes(Array("1234".utf8)).compare(.bytes(Array("2345".utf8))) == .int(-1))
    #expect(Value.bytes(Array("2345".utf8)).compare(.bytes(Array("1234".utf8))) == .int(1))
    #expect(Value.bytes(Array("2345".utf8)).compare(.bytes(Array("2345".utf8))) == .int(0))
    #expect(Value.bytes(Array("1".utf8)).compare(.string("1")).isError)
  }

  @Test func convertToType() {
    #expect(Value.bytes(Array("hello world".utf8)).convert(to: .bytes) == .bytes(Array("hello world".utf8)))
    #expect(Value.bytes(Array("hello world".utf8)).convert(to: .string) == "hello world")
    #expect(Value.bytes(Array("hello world".utf8)).convert(to: .type(nil)) == .type(.bytes))
    #expect(Value.bytes(Array("hello".utf8)).convert(to: .int).isError)
    #expect(
      Value.bytes([0xFF, 0xFE]).convert(to: .string)
        == .error(EvalError("invalid UTF-8 in bytes, cannot convert to string")))
  }

  @Test func sizeAndZero() {
    #expect(Value.bytes(Array("1234567890".utf8)).size() == 10)
    #expect(Value.bytes([]).isZeroValue)
    #expect(Value.bytes([0]).isZeroValue == false)
  }
}

struct DoubleValueTests {
  @Test func add() {
    #expect(Value.double(4).add(.double(-3.5)) == 0.5)
    #expect(Value.double(-1).add(.string("-1")).isError)
  }

  @Test(arguments: [
    (Value.double(42), Value.double(42), Value.int(0)),
    (.double(42), .uint(42), .int(0)),
    (.double(42), .int(42), .int(0)),
    (.double(-1300), .double(204), .int(-1)),
    (.double(-1300), .uint(204), .int(-1)),
    (.double(203.9), .int(204), .int(-1)),
    (.double(1300), .uint(UInt64(Int64.max) + 1), .int(-1)),
    (.double(204), .uint(205), .int(-1)),
    (.double(204), .double(Double(Int64.max) + 1025.0), .int(-1)),
    (.double(204), .double(.nan), .error(EvalError("NaN values cannot be ordered"))),
    (.double(.nan), .double(204), .error(EvalError("NaN values cannot be ordered"))),
    (.double(204), .double(-1300), .int(1)),
    (.double(204), .uint(10), .int(1)),
    (.double(204.1), .int(204), .int(1)),
    (.double(1), .string("1"), .error(EvalError("no such overload"))),
  ])
  func compare(a: Value, b: Value, out: Value) {
    #expect(a.compare(b) == out)
  }

  @Test(arguments: [
    (-4.2, CELType.double, Value.double(-4.2)),
    (-4.2, .type(nil), .type(.double)),
    (4.2, .int, .int(4)),
    (.nan, .int, .error(EvalError("integer overflow"))),
    (.infinity, .int, .error(EvalError("integer overflow"))),
    (Double(Int64.max), .int, .error(EvalError("integer overflow"))),
    (Double(Int64.min), .int, .error(EvalError("integer overflow"))),
    (4.7, .uint, .uint(4)),
    (.nan, .uint, .error(EvalError("unsigned integer overflow"))),
    (.infinity, .uint, .error(EvalError("unsigned integer overflow"))),
    (Double(UInt64.max), .uint, .error(EvalError("unsigned integer overflow"))),
    (-0.1, .uint, .error(EvalError("unsigned integer overflow"))),
    (4.5, .string, .string("4.5")),
    (4, .mapOfDyn, .error(EvalError("type conversion error from 'double' to 'map(dyn, dyn)'"))),
  ])
  func convertToType(input: Double, type: CELType, out: Value) {
    #expect(Value.double(input).convert(to: type) == out)
  }

  @Test func divide() {
    #expect(Value.double(3).divide(.double(1.5)) == 2.0)
    #expect(Value.double(1.1).divide(.double(0)) == .double(.infinity))
    #expect(Value.double(1.1).divide(.int(-1)).isError)
  }

  @Test(arguments: [
    (Value.double(-10), Value.double(-10), true),
    (.double(-10), .double(10), false),
    (.double(10), .uint(10), true),
    (.double(9), .uint(10), false),
    (.double(10), .int(10), true),
    (.double(10), .int(-15), false),
    (.double(.nan), .int(10), false),
  ])
  func equal(a: Value, b: Value, out: Bool) {
    #expect(a.celEquals(b) == .bool(out))
  }

  @Test func isZeroValue() {
    #expect(Value.double(.infinity).isZeroValue == false)
    #expect(Value.double(-.infinity).isZeroValue == false)
    #expect(Value.double(.nan).isZeroValue == false)
    #expect(Value.double(0).isZeroValue)
  }

  @Test func arithmetic() {
    #expect(Value.double(1.1).multiply(.double(-1.2)).celEquals(.double(-1.32)) == true)
    #expect(Value.double(1.1).multiply(.int(-1)).isError)
    #expect(Value.double(1.1).negate() == -1.1)
    #expect(Value.double(4).subtract(.double(-3.5)) == 7.5)
    #expect(Value.double(1.1).subtract(.int(-1)).isError)
  }
}

struct StringValueTests {
  @Test func add() {
    #expect(Value.string("hello").add(.string(" world")) == "hello world")
    #expect(Value.string("goodbye").add(.int(1)).isError)
  }

  @Test func compare() {
    #expect(Value.string("a").compare(.string("bbbb")) == .int(-1))
    #expect(Value.string("a").compare(.string("a")) == .int(0))
    #expect(Value.string("c").compare(.string("bbbb")) == .int(1))
    #expect(Value.string("a").compare(.bool(true)).isError)
    // Byte-wise UTF-8 order as Go, not canonical equivalence: C3 A9 sorts after 65 CC 81.
    #expect(Value.string("\u{E9}").compare(.string("e\u{301}")) == .int(1))
  }

  @Test func convertToType() {
    #expect(Value.string("-1").convert(to: .int) == -1)
    #expect(Value.string("false").convert(to: .bool) == false)
    #expect(Value.string("1").convert(to: .uint) == .uint(1))
    #expect(Value.string("2017-01-01T00:00:00Z").convert(to: .timestamp) == ts(1_483_228_800))
    #expect(Value.string("1h5s").convert(to: .duration) == dur(3605))
    #expect(Value.string("2.5").convert(to: .double) == 2.5)
    #expect(Value.string("hello").convert(to: .bytes) == .bytes(Array("hello".utf8)))
    #expect(Value.string("goodbye").convert(to: .type(nil)) == .type(.string))
    #expect(Value.string("goodbye").convert(to: .string) == "goodbye")
    #expect(Value.string("map{}").convert(to: .mapOfDyn).isError)
  }

  @Test func convertToTimestampStrict() {
    let valid = [
      "2025-01-17T01:00:00.001Z", "2025-01-01T12:34:56Z", "2025-01-01T12:34:56.123456789Z",
      "2025-01-01T12:34:56+05:30", "2025-01-01T12:34:56-08:00", "2025-01-01T12:34:56+14:00",
    ]
    for s in valid {
      #expect(Value.string(s).convert(to: .timestamp).isError == false, "\(s)")
    }
    let invalid = [
      "2025-01-17T01:00:00,001Z", "2025-01-17T1:00:00Z", "2025-01-17T01:5:00Z",
      "2025-01-18T01:01:01.001+24:01", "2025-01-17T01:01:01.001+00:60",
    ]
    for s in invalid {
      #expect(
        Value.string(s).convert(to: .timestamp)
          == .error(EvalError("invalid RFC 3339 timestamp \"\(s)\"")), "\(s)")
    }
  }

  @Test func equalAndZero() {
    #expect(Value.string("hello").celEquals(.string("hello")) == true)
    #expect(Value.string("hello").celEquals(.string("hell")) == false)
    #expect(Value.string("c").celEquals(.int(99)) == false)
    // Unicode scalars, not canonical equivalence.
    #expect(Value.string("\u{E9}").celEquals(.string("e\u{301}")) == false)
    #expect(Value.string("\u{E9}") != Value.string("e\u{301}"))
    #expect(Value.string("").isZeroValue)
    #expect(Value.string("non-zero").isZeroValue == false)
  }

  @Test func match() {
    let str = Value.string("hello 1 world")
    #expect(str.match(.string("^hello")) == true)
    #expect(str.match(.string("\\d world$")) == true)
    #expect(str.match(.string("ello 1 worlds")) == false)
    #expect(str.match(.int(1)).isError)
  }

  @Test func receivers() {
    #expect(Value.string("goodbye").receive(function: "contains", overload: "contains_string", args: ["db"]) == true)
    #expect(Value.string("goodbye").receive(function: "contains", overload: "contains_string", args: ["ggood"]) == false)
    #expect(Value.string("goodbye").receive(function: "endsWith", overload: "ends_with_string", args: ["bye"]) == true)
    #expect(Value.string("goodbye").receive(function: "endsWith", overload: "ends_with_string", args: ["good"]) == false)
    #expect(Value.string("goodbye").receive(function: "startsWith", overload: "starts_with_string", args: ["good"]) == true)
    #expect(Value.string("goodbye").receive(function: "startsWith", overload: "starts_with_string", args: ["db"]) == false)
  }

  @Test func size() {
    #expect(Value.string("").size() == 0)
    #expect(Value.string("hello world").size() == 11)
    #expect(Value.string("\u{65e5}\u{672c}\u{8a9e}").size() == 3)
  }
}

struct NullValueTests {
  @Test func convertAndEqual() {
    #expect(Value.null.convert(to: .string) == "null")
    #expect(Value.null.convert(to: .null) == .null)
    #expect(Value.null.convert(to: .type(nil)) == .type(.null))
    #expect(Value.null.convert(to: .int).isError)
    #expect(Value.null.celEquals(.null) == true)
    #expect(Value.null.celEquals(.int(0)) == false)
    #expect(Value.int(0).celEquals(.null) == false)
    #expect(Value.error(EvalError("e")).celEquals(.null) == false)
    #expect(Value.null.isZeroValue)
    #expect(Value.null.celType == .null)
  }
}

struct DurationValueTests {
  @Test func operators() {
    let d = dur(7506, 567)
    let maxD = Value.duration(CELDuration(nanoseconds: .max))
    let minD = Value.duration(CELDuration(nanoseconds: .min))
    #expect(d.add(d) == dur(15012, 1134))
    #expect(maxD.add(dur(0, 1)) == .error(EvalError("integer overflow")))
    #expect(maxD.add(dur(1)) == .error(EvalError("integer overflow")))
    #expect(minD.add(dur(-1)) == .error(EvalError("integer overflow")))
    #expect(d.subtract(d) == dur(0))
    #expect(maxD.subtract(dur(0, -1)) == .error(EvalError("integer overflow")))
    #expect(minD.subtract(dur(0, 1)) == .error(EvalError("integer overflow")))
  }

  @Test func compare() {
    let d = dur(7506)
    let lt = dur(-10)
    #expect(d.compare(lt) == 1)
    #expect(lt.compare(d) == -1)
    #expect(d.compare(d) == 0)
    #expect(d.compare(.bool(false)).isError)
  }

  @Test func convertToType() {
    let d = dur(7506, 1000)
    #expect(d.convert(to: .string) == "7506.000001s")
    #expect(d.convert(to: .int) == 7_506_000_001_000)
    #expect(d.convert(to: .duration) == d)
    #expect(d.convert(to: .type(nil)) == .type(.duration))
    #expect(d.convert(to: .uint).isError)
  }

  @Test func negate() {
    #expect(dur(1234, 1).negate() == dur(-1234, -1))
    #expect(Value.duration(CELDuration(nanoseconds: .min)).negate().isError)
    #expect(Value.duration(CELDuration(nanoseconds: .max)).negate() == .duration(CELDuration(nanoseconds: .min + 1)))
  }

  @Test func accessors() {
    let d = dur(7506)
    #expect(d.receive(function: "getHours", overload: "duration_to_hours", args: []) == 2)
    #expect(d.receive(function: "getMinutes", overload: "duration_to_minutes", args: []) == 125)
    #expect(d.receive(function: "getSeconds", overload: "duration_to_seconds", args: []) == 7506)
    // cel-go TestDurationGetMilliseconds expects 7506000 (the whole duration in milliseconds); the spec's
    // milliseconds portion is 0 (docs/divergences.md).
    #expect(d.receive(function: "getMilliseconds", overload: "duration_to_milliseconds", args: []) == 0)
    #expect(dur(1, 234_000_000).receive(function: "getMilliseconds", overload: "", args: []) == 234)
    #expect(dur(-1, -234_000_000).receive(function: "getMilliseconds", overload: "", args: []) == -234)
    #expect(dur(0, 1).isZeroValue == false)
    #expect(dur(0).isZeroValue)
  }
}

struct TimestampValueTests {
  @Test func convertToType() {
    let t = ts(7654, 321)
    #expect(t.convert(to: .type(nil)) == .type(.timestamp))
    #expect(t.convert(to: .int) == 7654)
    #expect(t.convert(to: .string) == "1970-01-01T02:07:34.000000321Z")
    #expect(t.convert(to: .timestamp) == t)
    #expect(t.convert(to: .duration).isError)
  }

  @Test func operators() {
    let hour: Int64 = 3_600_000_000_000
    #expect(ts(3506).add(.duration(CELDuration(nanoseconds: hour - 1_000_000))) == ts(7105, 999_000_000))
    #expect(ts(3506).add(.duration(CELDuration(nanoseconds: hour + 1))) == ts(7106, 1))
    #expect(ts(.max).add(dur(1)) == .error(EvalError("integer overflow")))
    #expect(ts(CELTimestamp.maxSecondsSinceEpoch).add(dur(1)) == .error(EvalError("timestamp overflow")))
    #expect(ts(.max, 999_999_999).add(dur(0, 1)) == .error(EvalError("integer overflow")))
    #expect(ts(1).add(dur(0, 1)).add(dur(0, -999_999_999)) == ts(0, 2))
    #expect(ts(1).add(dur(0, 999_999_999)).add(dur(0, 999_999_999)) == ts(2, 999_999_998))
    #expect(ts(1).add(ts(1)) == .error(EvalError("no such overload")))

    #expect(ts(1).compare(ts(1)) == 0)
    #expect(ts(1).compare(ts(200)) == -1)
    #expect(ts(1000).compare(ts(200)) == 1)
    #expect(ts(1000).compare(dur(0, 1000)) == .error(EvalError("no such overload")))

    #expect(ts(100).subtract(ts(1)) == dur(99))
    #expect(ts(3506).subtract(dur(3600)) == ts(-94))
    #expect(ts(-62_135_596_800).subtract(dur(1)) == .error(EvalError("timestamp overflow")))
    #expect(ts(-62_135_596_800, 2).subtract(dur(0, -999_999_999)) == ts(-62_135_596_799, 1))
    #expect(ts(.min).subtract(dur(0, 1)) == .error(EvalError("integer overflow")))
    #expect(ts(2, 1).subtract(ts(0, 999_999_999)) == dur(1, 2))
    #expect(ts(1, 1).subtract(ts(2, 999_999_999)) == dur(-2, 2))
    #expect(ts(.min).subtract(ts(1)) == .error(EvalError("integer overflow")))
    #expect(
      ts(CELTimestamp.maxSecondsSinceEpoch).subtract(ts(CELTimestamp.minSecondsSinceEpoch))
        == .error(EvalError("integer overflow")))
    #expect(ts(.min, 1).subtract(ts(-1, 1)) == .error(EvalError("integer overflow")))
    #expect(ts(1).subtract(.duration(CELDuration(nanoseconds: .min))) == .error(EvalError("integer overflow")))
  }

  @Test func isZeroValue() {
    #expect(ts(0).isZeroValue == false)
    #expect(ts(CELTimestamp.minSecondsSinceEpoch).isZeroValue)
  }

  @Test func accessors() {
    // 1970-01-01T02:05:06Z
    let t = ts(7506)
    func get(_ fn: String, _ args: Value...) -> Value {
      t.receive(function: fn, overload: "", args: args)
    }
    #expect(get("getDayOfMonth") == 0)
    #expect(get("getDayOfMonth", "America/Phoenix") == 30)
    #expect(get("getDayOfMonth", "-07:00") == 30)
    #expect(get("getDate") == 1)
    #expect(get("getDate", "America/Phoenix") == 31)
    #expect(get("getDate", "+23:00") == 2)
    #expect(get("getDayOfYear") == 0)
    #expect(get("getDayOfYear", "America/Phoenix") == 364)
    #expect(get("getDayOfYear", "-07:00") == 364)
    #expect(get("getFullYear") == 1970)
    #expect(get("getFullYear", "America/Phoenix") == 1969)
    #expect(get("getMonth") == 0)
    #expect(get("getMonth", "America/Phoenix") == 11)
    #expect(get("getDayOfWeek") == 4)
    #expect(get("getDayOfWeek", "America/Phoenix") == 3)
    #expect(get("getHours") == 2)
    #expect(get("getHours", "America/Phoenix") == 19)
    for tz in ["+24:00", "-24:00", "+99:00", "-50:30"] {
      #expect(get("getHours", .string(tz)).isError, "\(tz)")
    }
    #expect(get("getMinutes") == 5)
    #expect(get("getMinutes", "America/Phoenix") == 5)
    #expect(get("getMinutes", "-08:30") == 35)
    for tz in ["+00:99", "-00:90", "+05:-30"] {
      #expect(get("getMinutes", .string(tz)).isError, "\(tz)")
    }
    #expect(get("getSeconds") == 6)
    #expect(get("getSeconds", "America/Phoenix") == 6)
    let withMillis = ts(7506, 1_000_000)
    #expect(withMillis.receive(function: "getMilliseconds", overload: "", args: []) == 1)
    #expect(withMillis.receive(function: "getMilliseconds", overload: "", args: ["America/Phoenix"]) == 1)
  }
}

struct OptionalValueTests {
  @Test func format() {
    #expect(Value.optional(nil).description == "optional.none()")
    #expect(Value.optional(.bool(true)).description == "optional.of(true)")
    #expect(Value.optional(.optional(.bool(false))).description == "optional.of(optional.of(false))")
  }

  @Test func convertToType() {
    #expect(Value.optional(nil).convert(to: .optionalOfDyn) == .optional(nil))
    #expect(Value.optional(nil).convert(to: .type(nil)) == .type(.optionalOfDyn))
    #expect(Value.optional(nil).convert(to: .error).isError)
    #expect(Value.optional(.bool(false)).celType == .optionalOfDyn)
  }

  @Test(arguments: [
    (Value.optional(nil), Value.optional(nil), true),
    (.int(1), .optional(nil), false),
    (.optional(.int(1)), .optional(nil), false),
    (.optional(nil), .optional(.int(1)), false),
    (.optional(.int(1)), .optional(.double(0)), false),
    (.optional(.int(1)), .optional(.double(1)), true),
    (.optional(.optional(.int(1))), .optional(.double(1)), false),
    (.optional(.optional(.int(1))), .optional(.optional(.optional(.double(1)))), false),
    (.optional(.double(1)), .optional(.optional(.int(1))), false),
    (.optional(.optional(.optional(.double(1)))), .optional(.optional(.int(1))), false),
  ])
  func equal(a: Value, b: Value, out: Bool) {
    #expect(a.celEquals(b) == .bool(out))
  }
}

struct UnknownValueTests {
  private func trail(_ variable: String, _ qualifiers: AttributeQualifier...) -> AttributeTrail {
    AttributeTrail(variable: variable, qualifierPath: qualifiers)
  }

  @Test func newAttribute() {
    #expect(AttributeTrail(variable: "") == .unspecified)
    #expect(AttributeTrail(variable: "v").matches(.unspecified) == false)
  }

  @Test(arguments: [
    (AttributeTrail.unspecified, AttributeTrail(variable: ""), true),
    (AttributeTrail(variable: "a"), AttributeTrail(variable: ""), false),
    (AttributeTrail(variable: "a"), AttributeTrail(variable: "a"), true),
    (AttributeTrail(variable: "a", qualifierPath: [.string("b")]), AttributeTrail(variable: "a"), false),
    (
      AttributeTrail(variable: "a", qualifierPath: [.string("b")]),
      AttributeTrail(variable: "a", qualifierPath: [.int(1)]), false
    ),
    (
      AttributeTrail(variable: "a", qualifierPath: [.int(1)]),
      AttributeTrail(variable: "a", qualifierPath: [.string("1")]), false
    ),
    (
      AttributeTrail(variable: "a", qualifierPath: [.uint(1)]),
      AttributeTrail(variable: "a", qualifierPath: [.string("1")]), false
    ),
    (
      AttributeTrail(variable: "a", qualifierPath: [.string("b")]),
      AttributeTrail(variable: "a", qualifierPath: [.string("b")]), true
    ),
    (
      AttributeTrail(variable: "a", qualifierPath: [.int(20)]),
      AttributeTrail(variable: "a", qualifierPath: [.uint(20)]), true
    ),
    (
      AttributeTrail(variable: "a", qualifierPath: [.uint(20)]),
      AttributeTrail(variable: "a", qualifierPath: [.int(20)]), true
    ),
    (
      AttributeTrail(variable: "a", qualifierPath: [.uint(21)]),
      AttributeTrail(variable: "a", qualifierPath: [.int(20)]), false
    ),
    (
      AttributeTrail(variable: "a", qualifierPath: [.int(20)]),
      AttributeTrail(variable: "a", qualifierPath: [.uint(21)]), false
    ),
    (
      AttributeTrail(variable: "a", qualifierPath: [.int(-1)]),
      AttributeTrail(variable: "a", qualifierPath: [.uint(0)]), false
    ),
    (
      AttributeTrail(variable: "a", qualifierPath: [.int(1)]),
      AttributeTrail(variable: "a", qualifierPath: [.uint(UInt64(Int64.max) + 1)]), false
    ),
  ])
  func attributeEquals(a: AttributeTrail, b: AttributeTrail, equal: Bool) {
    #expect(a.matches(b) == equal)
  }

  @Test func attributeString() {
    #expect(AttributeTrail.unspecified.description == "<unspecified>")
    #expect(trail("a").description == "a")
    #expect(trail("a", .bool(false)).description == "a[false]")
    #expect(trail("a", .string("b")).description == "a.b")
    #expect(trail("a", .string("b"), .string("$this")).description == #"a.b["$this"]"#)
    #expect(trail("a", .int(12)).description == "a[12]")
    #expect(trail("a", .uint(24)).description == "a[24u]")
  }

  @Test func contains() {
    let u3true = UnknownSet(expressionID: 3, attribute: trail("a", .bool(true)))
    let u4b = UnknownSet(expressionID: 4, attribute: trail("a", .string("b")))
    #expect(UnknownSet(expressionID: 1).contains(UnknownSet(expressionID: 1, attribute: .unspecified)))
    #expect(u3true.contains(u4b) == false)
    #expect(UnknownSet(expressionID: 3, attribute: trail("a", .string("b"))).contains(u4b) == false)
    #expect(
      UnknownSet(expressionID: 3, attribute: trail("a", .string("c"))).contains(
        UnknownSet(expressionID: 3, attribute: trail("a", .string("b")))) == false)
    #expect(u3true.merging(u4b).contains(u3true))
    #expect(u3true.contains(u3true.merging(u4b)) == false)
  }

  @Test func ids() {
    let merged = UnknownSet(expressionID: 4, attribute: trail("a", .string("b")))
      .merging(UnknownSet(expressionID: 3, attribute: trail("a", .bool(true))))
    #expect(merged.expressionIDs == [3, 4])
    #expect(merged.attributeTrails(forExpressionID: 3)?.map(\.description) == ["a[true]"])
    #expect(merged.attributeTrails(forExpressionID: 4)?.map(\.description) == ["a.b"])
    #expect(UnknownSet(expressionID: 1).expressionIDs == [1])
  }

  @Test func string() {
    #expect(UnknownSet(expressionID: 1).description == "<unspecified> (1)")
    #expect(UnknownSet(expressionID: 2, attribute: trail("a")).description == "a (2)")
    #expect(UnknownSet(expressionID: 3, attribute: trail("a", .bool(false))).description == "a[false] (3)")
    let merged = UnknownSet(expressionID: 3, attribute: trail("a", .bool(true)))
      .merging(UnknownSet(expressionID: 4, attribute: trail("a", .string("b"))))
    #expect(merged.description == "a[true] (3), a.b (4)")
    let same = UnknownSet(expressionID: 3, attribute: trail("a", .int(0)))
      .merging(UnknownSet(expressionID: 3, attribute: trail("a", .int(0))))
    #expect(same.description == "a[0] (3)")
    let two = UnknownSet(expressionID: 3, attribute: trail("a", .int(0)))
      .merging(UnknownSet(expressionID: 3, attribute: trail("a", .int(1))))
    #expect(two.description == "[a[0] a[1]] (3)")
  }

  @Test func maybeMergeUnknowns() {
    let x = UnknownSet(expressionID: 2, attribute: trail("x"))
    let y = UnknownSet(expressionID: 1, attribute: trail("y"))
    #expect(Value.maybeMergeUnknowns(.string(""), nil).1 == false)
    #expect(Value.maybeMergeUnknowns(.string(""), y).1)
    let (merged, isUnknown) = Value.maybeMergeUnknowns(.unknown(x), y)
    #expect(isUnknown)
    #expect(merged == x.merging(y))
    #expect(Value.maybeMergeUnknowns(.unknown(x), nil).0 == x)
    #expect(Value.unknown(x).celEquals(.int(1)) == .unknown(x))
    #expect(Value.unknown(x).convert(to: .int) == .unknown(x))
  }
}

struct ValueFormatTests {
  @Test func format() {
    let tests: [(Value, String)] = [
      (.null, "null"),
      (.bool(true), "true"),
      (.int(-1), "-1"),
      (.uint(2), "2u"),
      (.double(2), "2.0"),
      (.double(1e21), "1000000000000000000000.0"),
      (.double(0.1), "0.1"),
      (.double(.nan), #"double("NaN")"#),
      (.double(-.infinity), #"double("-Infinity")"#),
      (.string("a\"b\n"), #""a\"b\n""#),
      (.bytes([104, 0xFF]), #"b"\150\377""#),
      ([1, "two", 3.0], #"[1, "two", 3.0]"#),
      (["b": 1, "a": 2], #"{"a": 2, "b": 1}"#),
      (.type(.list(.int)), "list"),
      (dur(1, 500_000_000), #"duration("1.5s")"#),
      (Value.string("2009-02-13T23:31:30+01:00").convert(to: .timestamp), #"timestamp("2009-02-13T22:31:30Z")"#),
      (.error(EvalError("boom")), "boom"),
    ]
    for (value, want) in tests {
      #expect(value.description == want)
    }
  }
}

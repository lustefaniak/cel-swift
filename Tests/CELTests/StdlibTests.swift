// Tests of the standard library declarations and runtime bindings (cel-go common/stdlib/standard.go).
// Expected values and error messages were checked against cel-go v0.32.0 with tools/oracle.

import Testing

@testable import CEL

/// Calls the dispatch binding registered under a function name, as parse-only evaluation does.
private func call(_ function: String, _ args: Value...) throws -> Value {
  let decl = try #require(StandardLibrary.functions.first { $0.name == function })
  let binding = try #require(try decl.bindings().first { $0.name == function })
  return binding.call(args, functionName: function, overload: "", exprID: 0)
}

/// Calls the binding registered under an overload id, as checked evaluation does.
private func callOverload(_ function: String, _ overloadID: String, _ args: Value...) throws -> Value {
  let decl = try #require(StandardLibrary.functions.first { $0.name == function })
  let binding = try #require(try decl.bindings().first { $0.name == overloadID })
  return binding.call(args, functionName: function, overload: overloadID, exprID: 0)
}

struct StdlibTests {
  @Test func everyDeclarationBinds() throws {
    var names = Set<String>()
    for fn in StandardLibrary.functions {
      #expect(names.insert(fn.name).inserted, "duplicate function \(fn.name)")
      let bindings = try fn.bindings()
      #expect(bindings.contains { $0.name == fn.name }, "\(fn.name) has no dispatch binding")
    }
    #expect(StandardLibrary.functions.count == 47)
    #expect(StandardLibrary.types.map(\.name) == [
      "bool", "bytes", "double", "google.protobuf.Duration", "int", "list", "map", "null_type",
      "string", "google.protobuf.Timestamp", "type", "uint",
    ])
  }

  @Test func disabledDeclarations() {
    let disabled = StandardLibrary.functions.filter(\.isDeclarationDisabled).map(\.name)
    #expect(Set(disabled) == ["__not_strictly_false__", "_in_", "in"])
  }

  @Test func arithmetic() throws {
    #expect(try call("_+_", 1, 2) == 3)
    #expect(try call("_+_", "a", "b") == "ab")
    #expect(try call("_+_", [1], [2, 3]) == [1, 2, 3])
    #expect(try call("_+_", .int(.max), 1) == .error(EvalError("integer overflow")))
    #expect(try call("_+_", 1, "a") == .error(EvalError("no such overload")))
    #expect(try call("_+_", true, true) == .error(EvalError("no such overload: _+_")))
    #expect(try call("_-_", .uint(1), .uint(2)) == .error(EvalError("unsigned integer overflow")))
    #expect(try call("_*_", 2.5, 2.0) == 5.0)
    #expect(try call("_/_", 1, 0) == .error(EvalError("division by zero")))
    #expect(try call("_%_", 1, 0) == .error(EvalError("modulus by zero")))
    #expect(try call("_%_", 1.0, 2.0) == .error(EvalError("no such overload: _%_")))
    #expect(try call("-_", 5) == -5)
    #expect(try call("-_", true) == .error(EvalError("no such overload")))
    #expect(try call("!_", true) == false)
  }

  @Test func relations() throws {
    #expect(try call("_<_", 1, 2.5) == true)
    #expect(try call("_<_", .uint(1), -1) == false)
    #expect(try call("_<=_", 2, 2.0) == true)
    #expect(try call("_>_", "b", "a") == true)
    #expect(try call("_>=_", .bytes([1]), .bytes([1, 0])) == false)
    #expect(try call("_<_", .double(.nan), 1) == false)
    #expect(try call("_>=_", 1, .double(.nan)) == false)
    #expect(try call("_<_", 1, "a") == .error(EvalError("no such overload")))
    #expect(try call("_<_", [1], [2]) == .error(EvalError("no such overload: _<_")))
    #expect(
      try call(
        "_<_", .timestamp(CELTimestamp(secondsSinceEpoch: 1)),
        .timestamp(CELTimestamp(secondsSinceEpoch: 2))) == true)
    #expect(
      try call(
        "_>_", .duration(CELDuration(nanoseconds: 1)), .duration(CELDuration(nanoseconds: 2)))
        == false)
  }

  @Test func indexAndIn() throws {
    #expect(try call("_[_]", [1, 2, 3], 1) == 2)
    #expect(try call("_[_]", [1, 2, 3], .uint(2)) == 3)
    #expect(try call("_[_]", [1, 2, 3], 2.0) == 3)
    #expect(try call("_[_]", [1], 1.5) == .error(EvalError("unsupported index value 1.5 in list")))
    #expect(try call("_[_]", [1], 5) == .error(EvalError("index '5' out of range in list size '1'")))
    #expect(try call("_[_]", [1], "a") == .error(EvalError("unsupported index type 'string' in list")))
    #expect(try call("_[_]", ["a": 1], "b") == .error(EvalError("no such key: b")))
    #expect(try call("_[_]", [1: "one"], 1.0) == "one")
    #expect(try call("_[_]", [.uint(1): "one"], 1) == "one")
    #expect(try call("_[_]", 1, 1) == .error(EvalError("no such overload: _[_]")))
    #expect(try call("@in", 2, [1, 2, 3]) == true)
    #expect(try call("@in", 2.0, [1, 2, 3]) == true)
    #expect(try call("@in", "a", ["b": 1]) == false)
    #expect(try call("@in", .uint(1), [1: 1]) == true)
    #expect(try call("@in", 1, 1) == .error(EvalError("no such overload")))
  }

  @Test func size() throws {
    #expect(try call("size", "héllo") == 5)
    #expect(try call("size", "\u{1F600}") == 1)
    #expect(try call("size", .bytes([1, 2])) == 2)
    #expect(try call("size", [1, 2, 3]) == 3)
    #expect(try call("size", ["a": 1]) == 1)
    #expect(try call("size", 1) == .error(EvalError("no such overload: size")))
    #expect(try callOverload("contains", "contains_string", "abc", "b") == true)
  }

  @Test func conversions() throws {
    #expect(try call("int", 1.9) == 1)
    #expect(try call("int", -1.9) == -1)
    #expect(try call("int", 1e19) == .error(EvalError("integer overflow")))
    #expect(try call("int", "+5") == 5)
    #expect(try call("int", "1.0") == .error(EvalError("type conversion error from 'string' to 'int'")))
    #expect(try call("int", .duration(CELDuration(nanoseconds: 1_000_000_000))) == 1_000_000_000)
    #expect(try call("int", .timestamp(CELTimestamp(secondsSinceEpoch: 7))) == 7)
    #expect(try call("uint", "+5") == .error(EvalError("type conversion error from 'string' to 'uint'")))
    #expect(try call("uint", -1) == .error(EvalError("unsigned integer overflow")))
    #expect(try call("uint", 1.5) == .uint(1))
    #expect(try call("double", "1e3") == 1000.0)
    #expect(try call("double", .uint(5)) == 5.0)
    #expect(try call("string", 1.5e10) == "1.5e+10")
    #expect(try call("string", -1.23e4) == "-12300")
    #expect(try call("string", .uint(7)) == "7")
    #expect(try call("string", .bytes([0xFF])) == .error(EvalError("invalid UTF-8 in bytes, cannot convert to string")))
    #expect(try call("string", .duration(CELDuration(nanoseconds: 5_400_000_000_000))) == "5400s")
    #expect(try call("bool", "TRUE") == true)
    #expect(try call("bool", "tRue") == .error(EvalError("type conversion error from 'string' to 'bool'")))
    #expect(try call("bytes", "abc") == .bytes([97, 98, 99]))
    #expect(try call("type", 1) == .type(.int))
    #expect(try call("type", .type(.int)) == .type(.type(nil)))
    #expect(try call("type", [1]) == .type(.list(.dyn)))
    #expect(try call("dyn", "x") == "x")
    #expect(try call("timestamp", 1) == .timestamp(CELTimestamp(secondsSinceEpoch: 1)))
    #expect(
      try call("timestamp", "2009-02-13T23:31:30") == .error(EvalError(#"invalid RFC 3339 timestamp "2009-02-13T23:31:30""#)))
    #expect(try call("duration", "1h") == .duration(CELDuration(nanoseconds: 3_600_000_000_000)))
    #expect(try call("int", true) == .error(EvalError("no such overload: int(bool)")))
  }

  @Test func strings() throws {
    #expect(try call("contains", "hello world", "o w") == true)
    #expect(try call("contains", "hello", "") == true)
    #expect(try call("startsWith", "hello", "he") == true)
    #expect(try call("endsWith", "hello", "lo") == true)
    // Byte-wise, not canonical equivalence: a decomposed é does not contain a precomposed one.
    #expect(try call("contains", "e\u{301}", "\u{E9}") == false)
    #expect(try call("startsWith", "e\u{301}", "e") == true)
    #expect(try call("endsWith", "e\u{301}", "\u{301}") == true)
    #expect(try call("contains", 1, "a") == .error(EvalError("no such overload")))
  }

  @Test func timestampAndDurationAccessors() throws {
    let ts = Value.string("2023-07-14T10:30:45.123Z").convert(to: .timestamp)
    #expect(try call("getFullYear", ts) == 2023)
    #expect(try call("getMonth", ts) == 6)
    #expect(try call("getDate", ts) == 14)
    #expect(try call("getDayOfMonth", ts) == 13)
    #expect(try call("getDayOfWeek", ts) == 5)
    #expect(try call("getHours", ts, "America/Los_Angeles") == 3)
    #expect(try call("getMilliseconds", ts) == 123)
    #expect(try call("getHours", ts, "Nope/Zone") == .error(EvalError("unknown time zone Nope/Zone")))
    #expect(
      try call("getHours", ts, "-1:x") == .error(EvalError(#"strconv.Atoi: parsing "x": invalid syntax"#)))
    #expect(
      try call("getHours", ts, "24:00")
        == .error(EvalError("timezone offset hours out of range [-23, 23]: 24:00")))
    let d = Value.string("3723.456s").convert(to: .duration)
    #expect(try call("getHours", d) == 1)
    #expect(try call("getMinutes", d) == 62)
    #expect(try call("getSeconds", d) == 3723)
    #expect(try call("getMilliseconds", d) == 3_723_456)
    #expect(try call("getHours", "x") == .error(EvalError("no such overload: getHours(string)")))
  }

  @Test func timestampArithmetic() throws {
    let ts = Value.string("2009-02-13T23:31:30+01:00").convert(to: .timestamp)
    let oneHour = Value.duration(CELDuration(nanoseconds: 3_600_000_000_000))
    let later = try call("_+_", ts, oneHour)
    #expect(later.convert(to: .string) == "2009-02-14T00:31:30+01:00")
    #expect(try call("_-_", later, ts) == oneHour)
    let max = Value.string("9999-12-31T23:59:59Z").convert(to: .timestamp)
    #expect(try call("_+_", max, oneHour) == .error(EvalError("timestamp overflow")))
    #expect(
      try call("_-_", max, Value.string("0001-01-01T00:00:00Z").convert(to: .timestamp))
        == .error(EvalError("integer overflow")))
  }

  @Test func logicalPlaceholders() throws {
    #expect(try call("_&&_", true, true) == .error(EvalError("no such overload")))
    #expect(try call("_==_", 1, 1) == .error(EvalError("no such overload")))
    #expect(try call("@not_strictly_false", .error(EvalError("x"))) == true)
    #expect(try call("@not_strictly_false", false) == false)
  }

  @Test func strictness() throws {
    let err = Value.error(EvalError("boom"))
    let unknown1 = Value.unknown(UnknownSet(exprID: 1))
    let unknown2 = Value.unknown(UnknownSet(exprID: 2))
    #expect(try call("_+_", err, unknown1) == err)
    #expect(try call("_+_", unknown1, err) == err)
    #expect(
      try call("_+_", unknown1, unknown2)
        == .unknown(UnknownSet(exprID: 1).merging(UnknownSet(exprID: 2))))
    #expect(try call("size", unknown1) == unknown1)
    #expect(try call("@not_strictly_false", err) == true)
    #expect(try call("@not_strictly_false", unknown1) == true)
  }

  @Test func receiverFallback() {
    let ts = Value.string("2009-02-13T23:31:30+01:00").convert(to: .timestamp)
    // cel-go's Timestamp.Receive uses the timestamp's own location without a zone argument.
    #expect(ts.receive(function: "getHours", overload: "", args: []) == 23)
    #expect(ts.receive(function: "getHours", overload: "", args: ["UTC"]) == 22)
    #expect(Value.string("abc").receive(function: "contains", overload: "", args: ["b"]) == true)
    #expect(
      Value.duration(CELDuration(nanoseconds: 7_200_000_000_000)).receive(
        function: "getHours", overload: "", args: []) == 2)
    #expect(Value.int(1).receive(function: "getHours", overload: "", args: []) == .noSuchOverload)
  }

  @Test func matchesHook() throws {
    #expect(try call("matches", "abc", "a.c").isError)
    #expect(try call("matches", 1, "a") == .error(EvalError("no such overload: matches")))
  }
}

// Cases from cel-go ext/math_test.go, lists_test.go, sets_test.go, encoders_test.go,
// regex_test.go and network_test.go, called through the bindings until the interpreter can
// evaluate the expressions end to end.

import Testing

@testable import CEL
@testable import CELExtensions

struct MathTests {
  let d = Dispatcher(.math)

  @Test func leastAndGreatest() {
    #expect(d.call("math.@min", 1) == 1)
    #expect(d.call("math.@min", -1, .uint(1)) == -1)
    #expect(d.call("math.@min", .uint(1), -1.5) == -1.5)
    #expect(d.call("math.@min", list(5.4, 10, .uint(3), -5.0, 3.5)) == -5.0)
    #expect(d.call("math.@max", list(5.4, 10, .uint(3), -5.0, 3.5)) == 10)
    #expect(d.call("math.@max", 1, 1.0) == 1)
    #expect(errorMessage(d.call("math.@min", list())) == "math.@min(list) argument must not be empty")
    #expect(errorMessage(d.call("math.@max", list())) == "math.@max(list) argument must not be empty")
    #expect(
      errorMessage(d.call("math.@max", list(1, "a"))) == "no such overload: math.@max")
  }

  @Test func rounding() {
    #expect(d.call("math.ceil", 1.2) == 2.0)
    #expect(d.call("math.ceil", -1.2) == -1.0)
    #expect(d.call("math.floor", -1.2) == -2.0)
    #expect(d.call("math.round", 1.5) == 2.0)
    #expect(d.call("math.round", -1.5) == -2.0)
    #expect(d.call("math.round", 2.5) == 3.0)
    #expect(d.call("math.trunc", -1.9) == -1.0)
    #expect(d.call("math.isInf", .double(.infinity)) == true)
    #expect(d.call("math.isNaN", .double(.nan)) == true)
    #expect(d.call("math.isFinite", .double(.infinity)) == false)
  }

  @Test func signedness() {
    #expect(d.call("math.abs", -1) == 1)
    #expect(d.call("math.abs", -1.5) == 1.5)
    #expect(d.call("math.abs", .uint(3)) == .uint(3))
    #expect(errorMessage(d.call("math.abs", .int(.min))) == "integer overflow")
    #expect(d.call("math.sign", -42) == -1)
    #expect(d.call("math.sign", 0.0) == 0.0)
    #expect(d.call("math.sign", -0.3) == -1.0)
    #expect(d.call("math.sign", .uint(42)) == .uint(1))
  }

  @Test func bitwise() {
    #expect(d.call("math.bitAnd", 3, 5) == 1)
    #expect(d.call("math.bitOr", .uint(3), .uint(5)) == .uint(7))
    #expect(d.call("math.bitXor", 3, 5) == 6)
    #expect(d.call("math.bitNot", 1) == -2)
    #expect(d.call("math.bitNot", .uint(0)) == .uint(.max))
    #expect(d.call("math.bitShiftLeft", 1, 2) == 4)
    #expect(d.call("math.bitShiftLeft", 1, 200) == 0)
    #expect(d.call("math.bitShiftRight", -1024, 3) == 2_305_843_009_213_693_824)
    #expect(d.call("math.bitShiftRight", .uint(1024), 3) == .uint(128))
    #expect(errorMessage(d.call("math.bitShiftLeft", 1, -2)) == "math.bitShiftLeft() negative offset: -2")
    #expect(errorMessage(d.call("math.bitShiftRight", .uint(1), -2)) == "math.bitShiftRight() negative offset: -2")
  }

  @Test func sqrt() {
    #expect(d.call("math.sqrt", 49.0) == 7.0)
    #expect(d.call("math.sqrt", 81) == 9.0)
    #expect(d.call("math.sqrt", .uint(4)) == 2.0)
    guard case .double(let nan) = d.call("math.sqrt", -15) else {
      Issue.record("sqrt(-15) is not a double")
      return
    }
    #expect(nan.isNaN)
  }

  @Test func versions() throws {
    #expect(try Library.math(version: 0).bindings()["math.ceil"] == nil)
    #expect(try Library.math(version: 1).bindings()["math.sqrt"] == nil)
    #expect(try Library.math(version: 2).bindings()["math.sqrt"] != nil)
  }
}

struct ListsTests {
  let d = Dispatcher(.lists)

  @Test func slice() {
    #expect(d.call("slice", list(1, 2, 3, 4), 0, 4) == list(1, 2, 3, 4))
    #expect(d.call("slice", list(1, 2, 3, 4), 1, 3) == list(2, 3))
    #expect(d.call("slice", list(1, 2, 3, 4), 4, 4) == list())
    #expect(
      errorMessage(d.call("slice", list(1, 2), 3, 0))
        == "cannot slice(3, 0), start index must be less than or equal to end index")
    #expect(errorMessage(d.call("slice", list(1, 2), 0, 3)) == "cannot slice(0, 3), list is length 2")
    #expect(
      errorMessage(d.call("slice", list(1, 2), -5, 3))
        == "cannot slice(-5, 3), negative indexes not supported")
  }

  @Test func flatten() {
    #expect(d.call("flatten", list(list(1, 2), list(3, 4))) == list(1, 2, 3, 4))
    #expect(d.call("flatten", list(1, list(2, list(3, 4)))) == list(1, 2, list(3, 4)))
    #expect(d.call("flatten", list(1, list(2, list(3, 4))), 2) == list(1, 2, 3, 4))
    #expect(d.call("flatten", list(1, list(2, list(3, list(4)))), 0) == list(1, list(2, list(3, list(4)))))
    #expect(errorMessage(d.call("flatten", list(), -1)) == "level must be non-negative")
  }

  /// A host list nested `depth` levels deep, built lazily so that neither building nor releasing it
  /// recurses: `[[[...[1]...]], 2]`.
  struct DeepList: ListValue {
    let depth: Int
    var count: Int { 2 }
    func element(at index: Int) -> Value {
      if index == 1 {
        return .int(2)
      }
      return depth == 0 ? .int(1) : .list(DeepList(depth: depth - 1))
    }
  }

  /// cel-go recurses once per nesting level (Go stacks grow); host lists can be nested far deeper
  /// than a Swift thread's stack allows.
  @Test(.disabled("overflows the stack: flatten recurses once per nesting level"))
  func flattenDeepHostList() throws {
    let depth = 1_000_000
    let flat = d.call("flatten", .list(DeepList(depth: depth)), .int(Int64(depth) + 1))
    guard case .list(let result) = flat else {
      Issue.record("not a list: \(flat)")
      return
    }
    #expect(result.count == depth + 2)
    #expect(result.element(at: 0) == .int(1))
    #expect(result.element(at: 1) == .int(2))
    // A depth below the nesting stops there.
    let partial = d.call("flatten", .list(DeepList(depth: 10)), .int(2))
    #expect(partial == list(.list(DeepList(depth: 7)), 2, 2, 2))
  }

  @Test func sort() {
    #expect(d.call("sort", list(4, 3, 2, 1)) == list(1, 2, 3, 4))
    #expect(d.call("sort", list("d", "a", "b", "c")) == list("a", "b", "c", "d"))
    #expect(d.call("sort", list()) == list())
    #expect(errorMessage(d.call("sort", list(3, "a"))) == "list elements must have the same type")
    #expect(errorMessage(d.call("sort", list(list(1), list(2)))) == "list elements must be comparable")
    #expect(
      d.call("@sortByAssociatedKeys", list("foo", "bar", "baz"), list(3, 1, 2))
        == list("bar", "baz", "foo"))
    #expect(
      errorMessage(d.call("@sortByAssociatedKeys", list(1), list(1, 2)))
        == "@sortByAssociatedKeys() expected a list of the same size as the associated keys list, but got 1 and 2 elements respectively")
  }

  @Test func rangeReverseDistinct() {
    #expect(d.call("lists.range", 4) == list(0, 1, 2, 3))
    #expect(d.call("lists.range", 0) == list())
    #expect(errorMessage(d.call("lists.range", -1)) == "lists.range: size must be non-negative, got -1")
    let small = Dispatcher(.lists(maxRangeSize: 10))
    #expect(
      errorMessage(small.call("lists.range", 11)) == "lists.range: size 11 exceeds maximum allowed (10)")
    #expect(d.call("reverse", list(5, 1, 2, 3)) == list(3, 2, 1, 5))
    #expect(d.call("distinct", list(1, 2, 2, 1.0, .uint(1), "a")) == list(1, 2, "a"))
    #expect(d.call("distinct", list(list(1), list(1), list(2))) == list(list(1), list(2)))
  }
}

struct SetsTests {
  let d = Dispatcher(.sets)

  @Test func contains() {
    #expect(d.call("sets.contains", list(), list()) == true)
    #expect(d.call("sets.contains", list(1), list()) == true)
    #expect(d.call("sets.contains", list(1), list(1, 1)) == true)
    #expect(d.call("sets.contains", list(1, 2), list(2.0, .uint(1))) == true)
    #expect(d.call("sets.contains", list(1), list(2)) == false)
    #expect(d.call("sets.contains", list(list(1), list(2, 3)), list(list(2, 3.0))) == true)
  }

  @Test func equivalentAndIntersects() {
    #expect(d.call("sets.equivalent", list(), list()) == true)
    #expect(d.call("sets.equivalent", list(1), list(.uint(1), 1.0)) == true)
    #expect(d.call("sets.equivalent", list(1, 2), list(2, 2, 2)) == false)
    #expect(d.call("sets.intersects", list(1), list()) == false)
    #expect(d.call("sets.intersects", list(1), list(1, 2)) == true)
    #expect(d.call("sets.intersects", list(list(1), list(2, 3)), list(list(1, 2), list(2, 3.0))) == true)
  }
}

struct EncodersTests {
  let d = Dispatcher(.encoders)

  @Test func base64() {
    #expect(d.call("base64.encode", .bytes(Array("hello".utf8))) == "aGVsbG8=")
    #expect(d.call("base64.decode", "aGVsbG8=") == .bytes(Array("hello".utf8)))
    #expect(d.call("base64.decode", "aGVsbG8") == .bytes(Array("hello".utf8)))
    #expect(d.call("base64.decode", "aGVsbG8=\n") == .bytes(Array("hello".utf8)))
    #expect(errorMessage(d.call("base64.decode", "a===")) == "illegal base64 data at input byte 1")
    #expect(errorMessage(d.call("base64.decode", "!!")) == "illegal base64 data at input byte 0")
  }

  @Test func json() {
    let value: Value = [
      "b": 1, "a": list(1.5, 2.0, .null, true, "x<>&\u{2028}é"), "c": .bytes([1, 0xFF]),
      "d": .duration(CELDuration(nanoseconds: 1_500_000_000)),
    ]
    #expect(
      d.call("json.encode", value)
        == "{\"a\":[1.5,2,null,true,\"x\\u003c\\u003e\\u0026\\u2028é\"],\"b\":1,\"c\":\"Af8=\",\"d\":\"1.5s\"}")
    #expect(d.call("json.encode", 9_007_199_254_740_993) == "\"9007199254740993\"")
    #expect(d.call("json.encode", 9_007_199_254_740_991) == "9007199254740991")
    #expect(d.call("json.encode", .uint(.max)) == "\"18446744073709551615\"")
    #expect(d.call("json.encode", 1e21) == "1e+21")
    #expect(d.call("json.encode", 1e-7) == "1e-7")
    #expect(d.call("json.encode", 1e20) == "100000000000000000000")
    #expect(d.call("json.encode", 0.000001) == "0.000001")
    #expect(d.call("json.encode", -0.0) == "-0")
    #expect(d.call("json.encode", "\u{0}\u{1F}\t\u{08}") == "\"\\u0000\\u001f\\t\\b\"")
    #expect(d.call("json.encode", .optional(1)) == "1")
    #expect(
      errorMessage(d.call("json.encode", .double(.nan)))
        == "proto: google.protobuf.Value.number_value: invalid NaN value")
    #expect(
      errorMessage(d.call("json.encode", [1: 2])) == "unsupported type conversion from 'int' to string")
    #expect(errorMessage(d.call("json.encode", .type(.int))) == "type conversion not supported for 'type'")
  }
}

struct RegexTests {
  let d = Dispatcher(.regex)

  @Test func extract() {
    #expect(d.call("regex.extract", "hello world", "hello(.*)") == .optional(" world"))
    #expect(d.call("regex.extract", "item-A, item-B", "item-(\\w+)") == .optional("A"))
    #expect(d.call("regex.extract", "HELLO", "hello") == .optional(nil))
    #expect(d.call("regex.extract", "brand", "brand(.*)") == .optional(nil))
    #expect(d.call("regex.extract", "testuser@", "(?P<username>.*)@") == .optional("testuser"))
    #expect(
      errorMessage(d.call("regex.extract", "foo", "(f)(o)"))
        == "regular expression has more than one capturing group: \"(f)(o)\"")
    #expect(
      errorMessage(d.call("regex.extract", "foo", "("))
        == "error parsing regexp: missing closing ): `(`")
  }

  @Test func extractAll() {
    #expect(d.call("regex.extractAll", "id:123, id:456", "id:\\d+") == list("id:123", "id:456"))
    #expect(d.call("regex.extractAll", "id:123, id:456", "assa") == list())
    #expect(d.call("regex.extractAll", "id:123, id:456", "id:(\\d+)") == list("123", "456"))
    #expect(d.call("regex.extractAll", "a1 b c3", "[a-z](\\d)?") == list("1", "3"))
  }

  @Test func replace() {
    #expect(d.call("regex.replace", "abc", "$", "_end") == "abc_end")
    #expect(d.call("regex.replace", "a-b", "\\b", "|") == "|a|-|b|")
    #expect(d.call("regex.replace", "foo bar", "(fo)o (ba)r", "\\2 \\1") == "ba fo")
    #expect(d.call("regex.replace", "foo bar", "foo", "\\\\") == "\\ bar")
    #expect(d.call("regex.replace", "banana", "a", "x", 0) == "banana")
    #expect(d.call("regex.replace", "banana", "a", "x", 1) == "bxnana")
    #expect(d.call("regex.replace", "banana", "a", "x", 2) == "bxnxna")
    #expect(d.call("regex.replace", "banana", "a", "x", -12) == "bxnxnx")
    #expect(
      errorMessage(d.call("regex.replace", "id=123", "id=(?P<value>\\d+)", "value: \\values"))
        == "invalid replacement string: 'value: \\values' \\ must be followed by a digit or \\")
    #expect(
      errorMessage(d.call("regex.replace", "test", "(.)", "\\2"))
        == "replacement string references group 2 but regex has only 1 group(s)")
    #expect(
      errorMessage(d.call("regex.replace", "test", "(.)", "\\"))
        == "invalid replacement string: '\\' \\ not allowed at end")
  }
}

struct NetworkTests {
  let d = Dispatcher(.network)

  private func ip(_ s: String) -> Value {
    d.call("ip", .string(s))
  }

  private func cidr(_ s: String) -> Value {
    d.call("cidr", .string(s))
  }

  @Test func parsing() {
    #expect(d.call("isIP", "1.2.3.4") == true)
    #expect(d.call("isIP", "::1") == true)
    #expect(d.call("isIP", "invalid") == false)
    #expect(d.call("isIP", "fe80::1%en0") == false)
    #expect(d.call("isIP", "::ffff:1.2.3.4") == false)
    // The hexadecimal IPv4-mapped form is the IPv4 address (cel-spec network_ext; cel-go rejects it).
    #expect(d.call("isIP", "::ffff:c0a8:1") == true)
    #expect(ip("::ffff:c0a8:1") == ip("192.168.0.1"))
    #expect(d.call("family", ip("::ffff:c0a8:1")) == 4)
    #expect(d.call("isCIDR", "10.0.0.0/8") == true)
    #expect(d.call("isCIDR", "10.0.0.1/8") == true)
    #expect(d.call("isCIDR", "10.0.0.0/33") == false)
    #expect(
      errorMessage(ip("1.2.3"))
        == "IP Address \"1.2.3\" parse error during conversion from string: ParseAddr(\"1.2.3\"): IPv4 address too short")
    #expect(
      errorMessage(ip("fe80::1%en0")) == "IP address \"fe80::1%en0\" with zone value is not allowed")
    #expect(
      errorMessage(ip("::ffff:1.2.3.4")) == "IPv4-mapped IPv6 address \"::ffff:1.2.3.4\" is not allowed")
    #expect(
      errorMessage(cidr("10.0.0.0/33"))
        == "CIDR \"10.0.0.0/33\" parse error during conversion from string: netip.ParsePrefix(\"10.0.0.0/33\"): prefix length out of range")
    #expect(
      errorMessage(ip("2001:db8::g"))
        == "IP Address \"2001:db8::g\" parse error during conversion from string: ParseAddr(\"2001:db8::g\"): each colon-separated field must have at least one digit (at \"g\")")
  }

  @Test func inspection() {
    #expect(d.call("family", ip("127.0.0.1")) == 4)
    #expect(d.call("family", ip("::1")) == 6)
    #expect(d.call("isLoopback", ip("127.0.0.1")) == true)
    #expect(d.call("isLoopback", ip("::1")) == true)
    #expect(d.call("isUnspecified", ip("0.0.0.0")) == true)
    #expect(d.call("isUnspecified", ip("::")) == true)
    #expect(d.call("isGlobalUnicast", ip("8.8.8.8")) == true)
    #expect(d.call("isGlobalUnicast", ip("255.255.255.255")) == false)
    #expect(d.call("isLinkLocalMulticast", ip("224.0.0.1")) == true)
    #expect(d.call("isLinkLocalMulticast", ip("ff02::1")) == true)
    #expect(d.call("isLinkLocalUnicast", ip("169.254.1.1")) == true)
    #expect(d.call("isLinkLocalUnicast", ip("fe80::1")) == true)
    #expect(d.call("ip.isCanonical", "2001:db8::1") == true)
    #expect(d.call("ip.isCanonical", "2001:DB8::1") == false)
    #expect(d.call("ip.isCanonical", "2001:db8:0:0:0:0:0:1") == false)
    #expect(d.call("string", ip("2001:db8:0:0:1:0:0:1")) == "2001:db8::1:0:0:1")
    #expect(d.call("string", ip("0:0:0:0:0:0:0:1")) == "::1")
  }

  @Test func cidrFunctions() {
    #expect(d.call("containsIP", cidr("10.0.0.0/8"), ip("10.0.0.1")) == true)
    #expect(d.call("containsIP", cidr("10.0.0.0/8"), "11.0.0.1") == false)
    #expect(d.call("containsIP", cidr("::/0"), "1.2.3.4") == false)
    #expect(d.call("containsCIDR", cidr("10.0.0.0/8"), "10.1.0.0/16") == true)
    #expect(d.call("containsCIDR", cidr("10.1.0.0/16"), cidr("10.0.0.0/8")) == false)
    #expect(d.call("ip", cidr("192.168.1.5/24")) == ip("192.168.1.5"))
    #expect(d.call("isMask", cidr("192.168.1.0/24")) == true)
    #expect(d.call("isMask", cidr("192.168.1.5/24")) == false)
    #expect(d.call("masked", cidr("192.168.1.5/24")) == cidr("192.168.1.0/24"))
    #expect(d.call("prefixLength", cidr("192.168.1.0/24")) == 24)
    #expect(d.call("string", cidr("2001:db8::1/32")) == "2001:db8::1/32")
  }
}

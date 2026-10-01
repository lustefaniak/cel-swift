// Cases from cel-go ext/strings_test.go, called through the bindings until the interpreter can
// evaluate the expressions end to end.

import Testing

@testable import CEL
@testable import CELExtensions

struct StringsTests {
  let d = Dispatcher(.strings)

  @Test func charAt() {
    #expect(d.call("charAt", "tacocat", 3) == "o")
    #expect(d.call("charAt", "tacocat", 7) == "")
    #expect(d.call("charAt", "©αT", 0) == "©")
    #expect(d.call("charAt", "©αT", 1) == "α")
    #expect(d.call("charAt", "©αT", 2) == "T")
    #expect(errorMessage(d.call("charAt", "tacocat", 30)) == "index out of range: 30")
    #expect(errorMessage(d.call("charAt", "tacocat", -1)) == "index out of range: -1")
  }

  @Test func indexOf() {
    #expect(d.call("indexOf", "tacocat", "") == 0)
    #expect(d.call("indexOf", "tacocat", "ac") == 1)
    #expect(d.call("indexOf", "tacocat", "none") == -1)
    #expect(d.call("indexOf", "", "") == 0)
    #expect(d.call("indexOf", "", "a") == -1)
    #expect(d.call("indexOf", "tacocat", "", 3) == 3)
    #expect(d.call("indexOf", "tacocat", "a", 3) == 5)
    #expect(d.call("indexOf", "tacocat", "at", 3) == 5)
    #expect(d.call("indexOf", "ta©o©αT", "©") == 2)
    #expect(d.call("indexOf", "ta©o©αT", "©", 3) == 4)
    #expect(d.call("indexOf", "ta©o©αT", "©αT", 3) == 4)
    #expect(d.call("indexOf", "ta©o©αT", "©α", 5) == -1)
    #expect(d.call("indexOf", "ijk", "k") == 2)
    #expect(d.call("indexOf", "hello wello", "hello wello") == 0)
    #expect(d.call("indexOf", "hello wello", "ello", 6) == 7)
    #expect(d.call("indexOf", "hello wello", "elbo room!!") == -1)
    #expect(d.call("indexOf", "hello", "", 10) == 5)
    #expect(d.call("indexOf", "hello", "l", 10) == -1)
    #expect(errorMessage(d.call("indexOf", "tacocat", "a", -1)) == "index out of range: -1")
  }

  @Test func lastIndexOf() {
    #expect(d.call("lastIndexOf", "tacocat", "") == 7)
    #expect(d.call("lastIndexOf", "tacocat", "at") == 5)
    #expect(d.call("lastIndexOf", "tacocat", "none") == -1)
    #expect(d.call("lastIndexOf", "", "") == 0)
    #expect(d.call("lastIndexOf", "", "a") == -1)
    #expect(d.call("lastIndexOf", "tacocat", "", 3) == 3)
    #expect(d.call("lastIndexOf", "tacocat", "a", 3) == 1)
    #expect(d.call("lastIndexOf", "ta©o©αT", "©") == 4)
    #expect(d.call("lastIndexOf", "ta©o©αT", "©", 3) == 2)
    #expect(d.call("lastIndexOf", "ta©o©αT", "©α", 4) == 4)
    #expect(d.call("lastIndexOf", "hello wello", "hello wello") == 0)
    #expect(d.call("lastIndexOf", "hello wello", "low") == -1)
    #expect(d.call("lastIndexOf", "hello wello", "ello", 6) == 1)
    #expect(d.call("lastIndexOf", "hello", "", 10) == 5)
    #expect(errorMessage(d.call("lastIndexOf", "tacocat", "a", -1)) == "index out of range: -1")
  }

  @Test func asciiCase() {
    #expect(d.call("lowerAscii", "TacoCat") == "tacocat")
    #expect(d.call("lowerAscii", "TacoCÆt Xii") == "tacocÆt xii")
    #expect(d.call("upperAscii", "tacoCat") == "TACOCAT")
    #expect(d.call("upperAscii", "tacoCαt") == "TACOCαT")
  }

  @Test func replace() {
    #expect(d.call("replace", "12 days 12 hours", "{0}", "2") == "12 days 12 hours")
    #expect(d.call("replace", "{0} days {0} hours", "{0}", "2") == "2 days 2 hours")
    #expect(d.call("replace", "{0} days {0} hours", "{0}", "2", 1) == "2 days {0} hours")
    #expect(d.call("replace", "{0} days {0} hours", "{0}", "2", -1) == "2 days 2 hours")
    #expect(d.call("replace", "{0} days {0} hours", "{0}", "2", 0) == "{0} days {0} hours")
    #expect(d.call("replace", "ta©o©αT", "©", "©α") == "ta©αo©ααT")
    #expect(d.call("replace", "hello", "", "_") == "_h_e_l_l_o_")
    #expect(d.call("replace", "héllo", "", "_", 3) == "_h_é_llo")
  }

  @Test func split() {
    #expect(d.call("split", "hello world", " ") == list("hello", "world"))
    #expect(d.call("split", "hello world events!", " ", 0) == list())
    #expect(d.call("split", "hello world events!", " ", 1) == list("hello world events!"))
    #expect(d.call("split", "hello world events!", " ", 2) == list("hello", "world events!"))
    #expect(d.call("split", "hello world events!", " ", -1) == list("hello", "world", "events!"))
    #expect(d.call("split", "o©o©o", "©", 3) == list("o", "o", "o"))
    #expect(d.call("split", "o©o©o", "©", -1) == list("o", "o", "o"))
    #expect(d.call("split", "a©b", "") == list("a", "©", "b"))
    #expect(d.call("split", "abc", "", 2) == list("a", "bc"))
    #expect(d.call("split", "", ",") == list(""))
  }

  @Test func substring() {
    #expect(d.call("substring", "tacocat", 4) == "cat")
    #expect(d.call("substring", "tacocat", 7) == "")
    #expect(d.call("substring", "tacocat", 0, 4) == "taco")
    #expect(d.call("substring", "tacocat", 4, 4) == "")
    #expect(d.call("substring", "ta©o©αT", 2, 6) == "©o©α")
    #expect(d.call("substring", "ta©o©αT", 7, 7) == "")
    #expect(errorMessage(d.call("substring", "tacocat", 40)) == "index out of range: 40")
    #expect(errorMessage(d.call("substring", "tacocat", -1)) == "index out of range: -1")
    #expect(errorMessage(d.call("substring", "tacocat", 1, 50)) == "index out of range: 50")
    #expect(errorMessage(d.call("substring", "tacocat", 49, 50)) == "index out of range: 49")
    #expect(errorMessage(d.call("substring", "tacocat", 4, 3)) == "invalid substring range. start: 4, end: 3")
  }

  @Test func trim() {
    #expect(d.call("trim", " \u{0C}\n\r\t\u{0B}text  ") == "text")
    #expect(d.call("trim", "\u{0085}\u{00A0}\u{1680}text") == "text")
    #expect(d.call("trim", "text\u{2000}\u{2001}\u{2002}\u{2003}\u{2004}\u{2005}\u{2006}\u{2007}\u{2008}\u{2009}") == "text")
    #expect(d.call("trim", "\u{200A}\u{2028}\u{2029}\u{202F}\u{205F}\u{3000}text") == "text")
    // Zero-width spaces are not white space.
    #expect(d.call("trim", "\u{180E}\u{200B}\u{200C}\u{200D}\u{2060}\u{FEFF}text") == "\u{180E}\u{200B}\u{200C}\u{200D}\u{2060}\u{FEFF}text")
  }

  @Test func join() {
    #expect(d.call("join", list("x", "y")) == "xy")
    #expect(d.call("join", list("x", "y"), "-") == "x-y")
    #expect(d.call("join", list()) == "")
    #expect(d.call("join", list(), "-") == "")
    #expect(errorMessage(d.call("join", list("x", 1))) == "join: invalid input: 1")
  }

  @Test func quote() {
    #expect(d.call("strings.quote", "first\nsecond") == "\"first\\nsecond\"")
    #expect(d.call("strings.quote", "bell\u{07}") == "\"bell\\a\"")
    #expect(d.call("strings.quote", "\u{08}\u{0C}\r\t\u{0B}\\\"") == "\"\\b\\f\\r\\t\\v\\\\\\\"\"")
    #expect(d.call("strings.quote", "printable unicode😀") == "\"printable unicode😀\"")
    #expect(d.call("strings.quote", "") == "\"\"")
  }

  @Test func reverse() {
    #expect(d.call("reverse", "gums") == "smug")
    #expect(d.call("reverse", "John Smith") == "htimS nhoJ")
    #expect(d.call("reverse", "ta©o©αT") == "Tα©o©at")
    #expect(d.call("reverse", "") == "")
  }

  @Test func versions() throws {
    let v0 = try Library.strings(version: 0).bindings()
    #expect(v0["format"] == nil)
    #expect(v0["reverse"] == nil)
    let v2 = try Library.strings(version: 2).bindings()
    #expect(v2["format"] != nil)
    #expect(v2["reverse"] == nil)
    let v0d = Dispatcher(.strings(version: 0))
    #expect(
      errorMessage(v0d.call("join", list("x", 1))) == "unsupported type conversion from 'int' to string")
  }

  @Test func format() {
    #expect(d.call("format", "%s %s", list("a", 1)) == "a 1")
    #expect(d.call("format", "%%%s%%", list("x")) == "%x%")
    #expect(
      d.call("format", "%s", list(list(.bytes([0x61]), "a\"b", 1.0, .null))) == "[a, a\"b, 1, null]")
    #expect(d.call("format", "%s", list(["b": 1, "a": list(.null)])) == "{a: [null], b: 1}")
    #expect(d.call("format", "%x|%X|%o|%b", list(-255, "héllo", -8, -5)) == "-ff|68C3A96C6C6F|-10|-101")
    #expect(d.call("format", "%d|%f", list(.double(-.infinity), .double(.nan))) == "-Infinity|NaN")
    #expect(d.call("format", "%s", list(.type(.list(.int)))) == "list")
    #expect(
      d.call("format", "%s", list(.duration(CELDuration(nanoseconds: -1_500_000_000)))) == "-1.5s")
    #expect(
      errorMessage(d.call("format", "%.200f", list(1.0)))
        == "could not parse formatting clause: error while parsing precision: precision 200 exceeds maximum allowed precision 100")
    #expect(
      errorMessage(d.call("format", "%.f", list(1.0)))
        == "could not parse formatting clause: error while parsing precision: error while converting precision to integer: strconv.Atoi: parsing \"\": invalid syntax")
    #expect(
      errorMessage(d.call("format", "%é", list(1.0)))
        == "could not parse formatting clause: unrecognized formatting clause \"Ã\"")
    #expect(errorMessage(d.call("format", "%", list(1.0))) == "unexpected end of string")
    #expect(errorMessage(d.call("format", "%s %s", list(1.0))) == "index 1 out of range")
    #expect(
      errorMessage(d.call("format", "%.3", list(1.0)))
        == "could not parse formatting clause: error while parsing precision: could not find end of precision specifier")
    #expect(
      errorMessage(d.call("format", "%s", list(.optional(1))))
        == "error during formatting: string clause can only be used on strings, bools, bytes, ints, doubles, maps, lists, types, durations, and timestamps, was given optional_type")
  }

  @Test func formatV1() {
    let v3 = Dispatcher(.strings(version: 3))
    let members: Value = list(.bytes([0x61]), "a\"b", 1.0, .double(-.infinity), .null)
    #expect(v3.call("format", "%s", list(members)) == "[b\"a\", \"a\\\"b\", 1.000000, \"-Inf\", null]")
    let map: Value = [1: "value1", 2: "value2", true: .double(.nan)]
    #expect(v3.call("format", "%s", list(map)) == "{1:\"value1\", 2:\"value2\", true:\"NaN\"}")
    #expect(v3.call("format", "%.2f|%e", list(-1234567.891, 1052.032911275))
      == "-1,234,567.89|1.052033\u{202F}×\u{202F}10⁰³")
    #expect(v3.call("format", "[%e][%.1e]", list("Infinity", .double(.nan))) == "[     ∞][NaN]")
    #expect(
      errorMessage(v3.call("format", "%d", list(1.5)))
        == "error during formatting: decimal clause can only be used on integers, was given double")
  }
}

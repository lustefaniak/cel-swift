// The calls cel-go makes into Go's regexp (common/types/string.go, common/types/regex.go,
// ext/regex.go, interpreter/optimizations.go), on String inputs, with expected values produced by
// running the same calls under Go 1.26.

import Testing

@testable import CELRegex

struct CELUsageTests {
  static let email = #"(?P<user>[a-z]+)@(?P<host>[a-z]+)\.com"#
  static let text = "mail ann@example.com and bob@test.com, zoë@x.com"

  @Test func subexpressions() throws {
    let re = try Regexp.compile(Self.email)
    #expect(re.numSubexp == 2)
    #expect(re.subexpNames == ["", "user", "host"])
    #expect(re.subexpIndex("host") == 2)
    #expect(re.subexpIndex("nope") == -1)
  }

  @Test func find() throws {
    let re = try Regexp.compile(Self.email)
    #expect(re.findString(Self.text) == "ann@example.com")
    #expect(re.findStringSubmatch(Self.text) == ["ann@example.com", "ann", "example"])
    #expect(re.findStringSubmatch("nothing here") == nil)
    #expect(re.findAllString(Self.text, 1) == ["ann@example.com"])
    #expect(
      re.findAllStringSubmatch(Self.text) == [["ann@example.com", "ann", "example"], ["bob@test.com", "bob", "test"]])
    #expect(re.findAllStringSubmatchIndex(Self.text) == [[5, 20, 5, 8, 9, 16], [25, 37, 25, 28, 29, 33]])
  }

  @Test func replace() throws {
    let re = try Regexp.compile(Self.email)
    #expect(
      re.replaceAllString(Self.text, "${host}:$1 $$ $3x $user")
        == "mail example:ann $  ann and test:bob $  bob, zoë@x.com")
    #expect(re.replaceAllLiteralString(Self.text, "$1") == "mail $1 and $1, zoë@x.com")
    let empty = try Regexp.compile("a*")
    #expect(empty.replaceAllString("baaac", "X") == "XbXcX")
    #expect(empty.findAllStringIndex("baaac") == [[0, 0], [1, 4], [5, 5]])
  }

  /// Offsets are UTF-8 byte offsets, as in Go.
  @Test func unicode() throws {
    let greek = try Regexp.compile(#"\p{Greek}+|ë"#)
    #expect(greek.findAllString("abc αβγ zoë ΩΩ") == ["αβγ", "ë", "ΩΩ"])
    #expect(greek.findAllStringIndex("abc αβγ zoë ΩΩ") == [[4, 10], [13, 15], [16, 20]])
    let fold = try Regexp.compile(#"(?i)straße|ǅ"#)
    #expect(fold.findAllString("STRASSE Straße STRAßE ǆ Ǆ ǅ") == ["Straße", "STRAßE", "ǆ", "Ǆ", "ǅ"])
  }

  @Test func matchStringAndErrors() throws {
    #expect(try Regexp.matchString(#"^\d{3}-\d{4}$"#, "555-1234"))
    #expect(throws: RegexpError(code: .missingParen, expr: "(")) { try Regexp.matchString("(", "x") }
    do {
      _ = try Regexp.compile("(")
    } catch {
      #expect(error.description == "error parsing regexp: missing closing ): `(`")
    }
  }

  /// cel-go's types.RegexProgramSize, checked against Go: "(a|b)*[0-9]+" is 8 (the size in
  /// cel-go's RegexProgramSizeLimit tests), "el*" is 5. Go panics on "a{2}"; see divergences.md.
  @Test func programSize() throws {
    #expect(try Regexp.programSize("(a|b)*[0-9]+") == 8)
    #expect(try Regexp.programSize("el*") == 5)
    #expect(try Regexp.programSize("abc") == 5)
    #expect(try Regexp.programSize("a{2}") == 4)
    #expect(try Regexp.programSize("x{2,5}") == 10)
    #expect(throws: RegexpError.self) { try Regexp.programSize("(") }
  }

  @Test func regexpIsSendable() async throws {
    let re = try Regexp.compile(Self.email)
    let results = await withTaskGroup(of: String.self) { group in
      for _ in 0..<8 {
        group.addTask { re.findString(Self.text) }
      }
      var out: [String] = []
      for await r in group {
        out.append(r)
      }
      return out
    }
    #expect(results == Array(repeating: "ann@example.com", count: 8))
  }
}

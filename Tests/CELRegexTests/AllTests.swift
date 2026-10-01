// Copyright 2009 The Go Authors. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

// Port of Go's regexp/all_test.go.
//
// Not ported: TestCopyMatch (no Copy; Regexp is a value type), TestDeepEqual (Regexp is an
// immutable value without a machine cache, so there is no state to diverge), TestUnmarshalText
// (no encoding.TextMarshaler), and the benchmarks.

import Testing

@testable import CELRegex

private let goodRe: [String] = [
  #""#,
  #"."#,
  #"^.$"#,
  #"a"#,
  #"a*"#,
  #"a+"#,
  #"a?"#,
  #"a|b"#,
  #"a*|b*"#,
  #"(a*|b)(c*|d)"#,
  #"[a-z]"#,
  #"[a-abc-c\-\]\[]"#,
  #"[a-z]+"#,
  #"[abc]"#,
  #"[^1234]"#,
  #"[^\n]"#,
  #"\!\\"#,
]

private let badRe: [(re: String, err: String)] = [
  (#"*"#, "missing argument to repetition operator: `*`"),
  (#"+"#, "missing argument to repetition operator: `+`"),
  (#"?"#, "missing argument to repetition operator: `?`"),
  (#"(abc"#, "missing closing ): `(abc`"),
  (#"abc)"#, "unexpected ): `abc)`"),
  (#"x[a-z"#, "missing closing ]: `[a-z`"),
  (#"[z-a]"#, "invalid character class range: `z-a`"),
  (#"abc\"#, "trailing backslash at end of expression"),
  (#"a**"#, "invalid nested repetition operator: `**`"),
  (#"a*+"#, "invalid nested repetition operator: `*+`"),
  (#"\x"#, "invalid escape sequence: `\\x`"),
  (String(repeating: #"\pL"#, count: 27000), "expression too large"),
]

@discardableResult
private func compileTest(_ expr: String, _ wantError: String) -> Regexp? {
  do {
    let re = try Regexp.compile(expr)
    if !wantError.isEmpty {
      Issue.record("compiling `\(expr)`; missing error")
    }
    return re
  } catch {
    if wantError.isEmpty {
      Issue.record("compiling `\(expr)`; unexpected error: \(error.description)")
    } else if !error.description.contains(wantError) {
      Issue.record("compiling `\(expr)`; wrong error: \(error.description); want \(wantError)")
    }
    return nil
  }
}

struct ReplaceTest: Sendable, CustomTestStringConvertible {
  var pattern, replacement, input, output: String
  init(_ pattern: String, _ replacement: String, _ input: String, _ output: String) {
    self.pattern = pattern
    self.replacement = replacement
    self.input = input
    self.output = output
  }
  var testDescription: String { "\(goQuote(pattern)) \(goQuote(replacement)) \(goQuote(input))" }
}

let replaceTests: [ReplaceTest] = [
  // Test empty input and/or replacement, with pattern that matches the empty string.
  .init("", "", "", ""),
  .init("", "x", "", "x"),
  .init("", "", "abc", "abc"),
  .init("", "x", "abc", "xaxbxcx"),

  // Test empty input and/or replacement, with pattern that does not match the empty string.
  .init("b", "", "", ""),
  .init("b", "x", "", ""),
  .init("b", "", "abc", "ac"),
  .init("b", "x", "abc", "axc"),
  .init("y", "", "", ""),
  .init("y", "x", "", ""),
  .init("y", "", "abc", "abc"),
  .init("y", "x", "abc", "abc"),

  // Multibyte characters -- verify that we don't try to match in the middle
  // of a character.
  .init("[a-c]*", "x", "\u{65e5}", "x\u{65e5}x"),
  .init("[^\u{65e5}]", "x", "abc\u{65e5}def", "xxx\u{65e5}xxx"),

  // Start and end of a string.
  .init("^[a-c]*", "x", "abcdabc", "xdabc"),
  .init("[a-c]*$", "x", "abcdabc", "abcdx"),
  .init("^[a-c]*$", "x", "abcdabc", "abcdabc"),
  .init("^[a-c]*", "x", "abc", "x"),
  .init("[a-c]*$", "x", "abc", "x"),
  .init("^[a-c]*$", "x", "abc", "x"),
  .init("^[a-c]*", "x", "dabce", "xdabce"),
  .init("[a-c]*$", "x", "dabce", "dabcex"),
  .init("^[a-c]*$", "x", "dabce", "dabce"),
  .init("^[a-c]*", "x", "", "x"),
  .init("[a-c]*$", "x", "", "x"),
  .init("^[a-c]*$", "x", "", "x"),

  .init("^[a-c]+", "x", "abcdabc", "xdabc"),
  .init("[a-c]+$", "x", "abcdabc", "abcdx"),
  .init("^[a-c]+$", "x", "abcdabc", "abcdabc"),
  .init("^[a-c]+", "x", "abc", "x"),
  .init("[a-c]+$", "x", "abc", "x"),
  .init("^[a-c]+$", "x", "abc", "x"),
  .init("^[a-c]+", "x", "dabce", "dabce"),
  .init("[a-c]+$", "x", "dabce", "dabce"),
  .init("^[a-c]+$", "x", "dabce", "dabce"),
  .init("^[a-c]+", "x", "", ""),
  .init("[a-c]+$", "x", "", ""),
  .init("^[a-c]+$", "x", "", ""),

  // Other cases.
  .init("abc", "def", "abcdefg", "defdefg"),
  .init("bc", "BC", "abcbcdcdedef", "aBCBCdcdedef"),
  .init("abc", "", "abcdabc", "d"),
  .init("x", "xXx", "xxxXxxx", "xXxxXxxXxXxXxxXxxXx"),
  .init("abc", "d", "", ""),
  .init("abc", "d", "abc", "d"),
  .init(".+", "x", "abc", "x"),
  .init("[a-c]*", "x", "def", "xdxexfx"),
  .init("[a-c]+", "x", "abcbcdcdedef", "xdxdedef"),
  .init("[a-c]*", "x", "abcbcdcdedef", "xdxdxexdxexfx"),

  // Substitutions
  .init("a+", "($0)", "banana", "b(a)n(a)n(a)"),
  .init("a+", "(${0})", "banana", "b(a)n(a)n(a)"),
  .init("a+", "(${0})$0", "banana", "b(a)an(a)an(a)a"),
  .init("a+", "(${0})$0", "banana", "b(a)an(a)an(a)a"),
  .init("hello, (.+)", "goodbye, ${1}", "hello, world", "goodbye, world"),
  .init("hello, (.+)", "goodbye, $1x", "hello, world", "goodbye, "),
  .init("hello, (.+)", "goodbye, ${1}x", "hello, world", "goodbye, worldx"),
  .init("hello, (.+)", "<$0><$1><$2><$3>", "hello, world", "<hello, world><world><><>"),
  .init("hello, (?P<noun>.+)", "goodbye, $noun!", "hello, world", "goodbye, world!"),
  .init("hello, (?P<noun>.+)", "goodbye, ${noun}", "hello, world", "goodbye, world"),
  .init("(?P<x>hi)|(?P<x>bye)", "$x$x$x", "hi", "hihihi"),
  .init("(?P<x>hi)|(?P<x>bye)", "$x$x$x", "bye", "byebyebye"),
  .init("(?P<x>hi)|(?P<x>bye)", "$xyz", "hi", ""),
  .init("(?P<x>hi)|(?P<x>bye)", "${x}yz", "hi", "hiyz"),
  .init("(?P<x>hi)|(?P<x>bye)", "hello $$x", "hi", "hello $x"),
  .init("a+", "${oops", "aaa", "${oops"),
  .init("a+", "$$", "aaa", "$"),
  .init("a+", "$", "aaa", "$"),

  // Substitution when subexpression isn't found
  .init("(x)?", "$1", "123", "123"),
  .init("abc", "$1", "123", "123"),

  // Substitutions involving a (x){0}
  .init("(a)(b){0}(c)", ".$1|$3.", "xacxacx", "x.a|c.x.a|c.x"),
  .init("(a)(((b))){0}c", ".$1.", "xacxacx", "x.a.x.a.x"),
  .init("((a(b){0}){3}){5}(h)", "y caramb$2", "say aaaaaaaaaaaaaaaah", "say ay caramba"),
  .init("((a(b){0}){3}){5}h", "y caramb$2", "say aaaaaaaaaaaaaaaah", "say ay caramba"),
]

let replaceLiteralTests: [ReplaceTest] = [
  // Substitutions
  .init("a+", "($0)", "banana", "b($0)n($0)n($0)"),
  .init("a+", "(${0})", "banana", "b(${0})n(${0})n(${0})"),
  .init("a+", "(${0})$0", "banana", "b(${0})$0n(${0})$0n(${0})$0"),
  .init("a+", "(${0})$0", "banana", "b(${0})$0n(${0})$0n(${0})$0"),
  .init("hello, (.+)", "goodbye, ${1}", "hello, world", "goodbye, ${1}"),
  .init("hello, (?P<noun>.+)", "goodbye, $noun!", "hello, world", "goodbye, $noun!"),
  .init("hello, (?P<noun>.+)", "goodbye, ${noun}", "hello, world", "goodbye, ${noun}"),
  .init("(?P<x>hi)|(?P<x>bye)", "$x$x$x", "hi", "$x$x$x"),
  .init("(?P<x>hi)|(?P<x>bye)", "$x$x$x", "bye", "$x$x$x"),
  .init("(?P<x>hi)|(?P<x>bye)", "$xyz", "hi", "$xyz"),
  .init("(?P<x>hi)|(?P<x>bye)", "${x}yz", "hi", "${x}yz"),
  .init("(?P<x>hi)|(?P<x>bye)", "hello $$x", "hi", "hello $$x"),
  .init("a+", "${oops", "aaa", "${oops"),
  .init("a+", "$$", "aaa", "$$"),
  .init("a+", "$", "aaa", "$"),
]

private let replaceFuncTests: [(pattern: String, replacement: @Sendable (String) -> String, input: String, output: String)] = [
  ("[a-c]", { "x" + $0 + "y" }, "defabcdef", "defxayxbyxcydef"),
  ("[a-c]+", { "x" + $0 + "y" }, "defabcdef", "defxabcydef"),
  ("[a-c]*", { "x" + $0 + "y" }, "defabcdef", "xydxyexyfxabcydxyexyfxy"),
]

struct MetaTest: Sendable {
  var pattern, output, literal: String
  var isLiteral: Bool
  init(_ pattern: String, _ output: String, _ literal: String, _ isLiteral: Bool) {
    self.pattern = pattern
    self.output = output
    self.literal = literal
    self.isLiteral = isLiteral
  }
}

private let metaTests: [MetaTest] = [
  .init(#""#, #""#, #""#, true),
  .init(#"foo"#, #"foo"#, #"foo"#, true),
  .init(#"日本語+"#, #"日本語\+"#, #"日本語"#, false),
  .init(#"foo\.\$"#, #"foo\\\.\\\$"#, #"foo.$"#, true),  // has meta but no operator
  .init(#"foo.\$"#, #"foo\.\\\$"#, #"foo"#, false),  // has escaped operators and real operators
  .init(#"!@#$%^&*()_+-=[{]}\|,<.>/?~"#, #"!@#\$%\^&\*\(\)_\+-=\[\{\]\}\\\|,<\.>/\?~"#, #"!@#"#, false),
]

private let literalPrefixTests: [MetaTest] = [
  // See golang.org/issue/11175.
  // output is unused.
  .init(#"^0^0$"#, #""#, #"0"#, false),
  .init(#"^0^"#, #""#, #""#, false),
  .init(#"^0$"#, #""#, #"0"#, true),
  .init(#"$0^"#, #""#, #""#, false),
  .init(#"$0$"#, #""#, #""#, false),
  .init(#"^^0$$"#, #""#, #""#, false),
  .init(#"^$^$"#, #""#, #""#, false),
  .init(#"$$0^^"#, #""#, #""#, false),
  .init(#"a\x{fffd}b"#, #""#, #"a"#, false),
  .init(#"\x{fffd}b"#, #""#, #""#, false),
  .init("\u{fffd}", #""#, #""#, false),
]

private let emptySubexpIndices: [(name: String, index: Int)] = [("", -1), ("missing", -1)]

private let subexpCases: [(input: String, num: Int, names: [String]?, indices: [(name: String, index: Int)])] = [
  (#""#, 0, nil, emptySubexpIndices),
  (#".*"#, 0, nil, emptySubexpIndices),
  (#"abba"#, 0, nil, emptySubexpIndices),
  (#"ab(b)a"#, 1, ["", ""], emptySubexpIndices),
  (#"ab(.*)a"#, 1, ["", ""], emptySubexpIndices),
  (#"(.*)ab(.*)a"#, 2, ["", "", ""], emptySubexpIndices),
  (#"(.*)(ab)(.*)a"#, 3, ["", "", "", ""], emptySubexpIndices),
  (#"(.*)((a)b)(.*)a"#, 4, ["", "", "", "", ""], emptySubexpIndices),
  (#"(.*)(\(ab)(.*)a"#, 3, ["", "", "", ""], emptySubexpIndices),
  (#"(.*)(\(a\)b)(.*)a"#, 3, ["", "", "", ""], emptySubexpIndices),
  (
    #"(?P<foo>.*)(?P<bar>(a)b)(?P<foo>.*)a"#, 4, ["", "foo", "bar", "", "foo"],
    [("", -1), ("missing", -1), ("foo", 1), ("bar", 2)]
  ),
]

private let splitTests: [(s: String, r: String, n: Int, out: [String])] = [
  ("foo:and:bar", ":", -1, ["foo", "and", "bar"]),
  ("foo:and:bar", ":", 1, ["foo:and:bar"]),
  ("foo:and:bar", ":", 2, ["foo", "and:bar"]),
  ("foo:and:bar", "foo", -1, ["", ":and:bar"]),
  ("foo:and:bar", "bar", -1, ["foo:and:", ""]),
  ("foo:and:bar", "baz", -1, ["foo:and:bar"]),
  ("baabaab", "a", -1, ["b", "", "b", "", "b"]),
  ("baabaab", "a*", -1, ["b", "b", "b"]),
  ("baabaab", "ba*", -1, ["", "", "", ""]),
  ("foobar", "f*b*", -1, ["", "o", "o", "a", "r"]),
  ("foobar", "f+.*b+", -1, ["", "ar"]),
  ("foobooboar", "o{2}", -1, ["f", "b", "boar"]),
  ("a,b,c,d,e,f", ",", 3, ["a", "b", "c,d,e,f"]),
  ("a,b,c,d,e,f", ",", 0, []),  // Go: nil
  (",", ",", -1, ["", ""]),
  (",,,", ",", -1, ["", "", "", ""]),
  ("", ",", -1, [""]),
  ("", ".*", -1, [""]),
  ("", ".+", -1, [""]),
  ("", "", -1, []),
  ("foobar", "", -1, ["f", "o", "o", "b", "a", "r"]),
  ("abaabaccadaaae", "a*", 5, ["", "b", "b", "c", "cadaaae"]),
  (":x:y:z:", ":", -1, ["", "x", "y", "z", ""]),
]

/// Go's strings.SplitN, for comparing Split against literal separators.
private func goSplitN(_ s: String, _ sep: String, _ n: Int) -> [String] {
  if n == 0 {
    return []
  }
  if sep.isEmpty {
    // explode: split into UTF-8 sequences, at most n.
    var out = s.unicodeScalars.map { String($0) }
    if n > 0 && out.count > n {
      let rest = out[(n - 1)...].joined()
      out = Array(out[..<(n - 1)]) + [rest]
    }
    return out
  }
  var out: [String] = []
  var rest = Substring(s)
  while n < 0 || out.count < n - 1 {
    guard let r = rest.range(of: sep) else { break }
    out.append(String(rest[..<r.lowerBound]))
    rest = rest[r.upperBound...]
  }
  out.append(String(rest))
  return out
}

private let minInputLenTests: [(regexp: String, min: Int)] = [
  (#""#, 0),
  (#"a"#, 1),
  (#"aa"#, 2),
  (#"(aa)a"#, 3),
  (#"(?:aa)a"#, 3),
  (#"a?a"#, 1),
  (#"(aaa)|(aa)"#, 2),
  (#"(aa)+a"#, 3),
  (#"(aa)*a"#, 1),
  (#"(aa){3,5}"#, 6),
  (#"[a-z]"#, 1),
  (#"日"#, 3),
]

struct AllTests {
  @Test func goodCompile() {
    for re in goodRe {
      compileTest(re, "")
    }
  }

  @Test func badCompile() {
    for tt in badRe {
      compileTest(tt.re, tt.err)
    }
  }

  @Test(arguments: findTests)
  func match(_ test: FindTest) {
    guard let re = compileTest(test.pat, "") else { return }
    let want = !(test.matches ?? []).isEmpty
    if let text = test.textString {
      #expect(re.matchString(text) == want, "MatchString failure on \(test.testDescription)")
    }
    // now try bytes
    #expect(re.match(test.text) == want, "Match failure on \(test.testDescription)")
  }

  @Test(arguments: findTests)
  func matchFunction(_ test: FindTest) {
    // Go returns early when MatchString succeeds (err == nil), so this effectively checks nothing
    // beyond compilation; ported as is.
    guard let text = test.textString else { return }
    guard let m = try? Regexp.matchString(test.pat, text) else { return }
    _ = m
  }

  @Test(arguments: replaceTests)
  func replaceAll(_ tc: ReplaceTest) throws {
    let re = try Regexp.compile(tc.pattern)
    var actual = re.replaceAllString(tc.input, tc.replacement)
    #expect(actual == tc.output, "\(goQuote(tc.pattern)).ReplaceAllString(\(goQuote(tc.input)),\(goQuote(tc.replacement)))")
    // now try bytes
    actual = String(decoding: re.replaceAll(Array(tc.input.utf8), Array(tc.replacement.utf8)), as: UTF8.self)
    #expect(actual == tc.output, "\(goQuote(tc.pattern)).ReplaceAll(\(goQuote(tc.input)),\(goQuote(tc.replacement)))")
  }

  @Test func replaceAllLiteral() throws {
    // Run ReplaceAll tests that do not have $ expansions.
    for tc in replaceTests where !tc.replacement.contains("$") {
      try checkReplaceLiteral(tc)
    }
    // Run literal-specific tests.
    for tc in replaceLiteralTests {
      try checkReplaceLiteral(tc)
    }
  }

  private func checkReplaceLiteral(_ tc: ReplaceTest) throws {
    let re = try Regexp.compile(tc.pattern)
    var actual = re.replaceAllLiteralString(tc.input, tc.replacement)
    #expect(actual == tc.output, "\(goQuote(tc.pattern)).ReplaceAllLiteralString(\(goQuote(tc.input)),\(goQuote(tc.replacement)))")
    // now try bytes
    actual = String(decoding: re.replaceAllLiteral(Array(tc.input.utf8), Array(tc.replacement.utf8)), as: UTF8.self)
    #expect(actual == tc.output, "\(goQuote(tc.pattern)).ReplaceAllLiteral(\(goQuote(tc.input)),\(goQuote(tc.replacement)))")
  }

  @Test func replaceAllFunc() throws {
    for tc in replaceFuncTests {
      let re = try Regexp.compile(tc.pattern)
      var actual = re.replaceAllStringFunc(tc.input, tc.replacement)
      #expect(actual == tc.output, "\(goQuote(tc.pattern)).ReplaceFunc(\(goQuote(tc.input)),fn)")
      // now try bytes
      actual = String(
        decoding: re.replaceAllFunc(Array(tc.input.utf8)) { Array(tc.replacement(String(decoding: $0, as: UTF8.self)).utf8) },
        as: UTF8.self)
      #expect(actual == tc.output, "\(goQuote(tc.pattern)).ReplaceFunc(\(goQuote(tc.input)),fn)")
    }
  }

  @Test func quoteMeta() throws {
    for tc in metaTests {
      // Verify that QuoteMeta returns the expected string.
      let quoted = Regexp.quoteMeta(tc.pattern)
      if quoted != tc.output {
        Issue.record("QuoteMeta(`\(tc.pattern)`) = `\(quoted)`; want `\(tc.output)`")
        continue
      }

      // Verify that the quoted string is in fact treated as expected
      // by Compile -- i.e. that it matches the original, unquoted string.
      if !tc.pattern.isEmpty {
        let re = try Regexp.compile(quoted)
        let src = "abc" + tc.pattern + "def"
        let repl = "xyz"
        let replaced = re.replaceAllString(src, repl)
        let expected = "abcxyzdef"
        #expect(replaced == expected, "QuoteMeta(`\(tc.pattern)`).Replace(`\(src)`,`\(repl)`)")
      }
    }
  }

  @Test func literalPrefix() throws {
    for tc in metaTests + literalPrefixTests {
      // Literal method needs to scan the pattern.
      let re = try Regexp.compile(tc.pattern)
      let (str, complete) = re.literalPrefix()
      #expect(complete == tc.isLiteral, "LiteralPrefix(`\(tc.pattern)`) complete")
      #expect(str == tc.literal, "LiteralPrefix(`\(tc.pattern)`)")
    }
  }

  @Test func subexp() throws {
    for c in subexpCases {
      let re = try Regexp.compile(c.input)
      let n = re.numSubexp
      if n != c.num {
        Issue.record("\(goQuote(c.input)): NumSubexp = \(n), want \(c.num)")
        continue
      }
      let names = re.subexpNames
      if names.count != 1 + n {
        Issue.record("\(goQuote(c.input)): len(SubexpNames) = \(names.count), want \(n)")
        continue
      }
      if let want = c.names {
        for i in 0..<(1 + n) {
          #expect(names[i] == want[i], "\(goQuote(c.input)): SubexpNames[\(i)]")
        }
      }
      for subexp in c.indices {
        let index = re.subexpIndex(subexp.name)
        #expect(index == subexp.index, "\(goQuote(c.input)): SubexpIndex(\(goQuote(subexp.name)))")
      }
    }
  }

  @Test func split() throws {
    for (i, test) in splitTests.enumerated() {
      let re = try Regexp.compile(test.r)

      let split = re.split(test.s, test.n)
      #expect(split == test.out, "#\(i): \(goQuote(test.r)): got \(split); want \(test.out)")

      if Regexp.quoteMeta(test.r) == test.r {
        let strsplit = goSplitN(test.s, test.r, test.n)
        #expect(split == strsplit, "#\(i): Split(\(goQuote(test.s)), \(goQuote(test.r)), \(test.n)): regexp vs strings mismatch")
      }
    }
  }

  /// The following sequence of Match calls used to panic. See issue #12980.
  @Test func parseAndCompile() throws {
    let expr = "a$"
    let s = "a\nb"

    for (i, tc) in [
      (reFlags: Syntax.Flags.perl.union(.oneLine), expMatch: false),
      (reFlags: Syntax.Flags.perl.subtracting(.oneLine), expMatch: true),
    ].enumerated() {
      let parsed = try Syntax.parse(expr, tc.reFlags)
      let re = try Regexp.compile(parsed.description)
      #expect(re.matchString(s) == tc.expMatch, "\(i): \(re).MatchString(\(goQuote(s)))")
    }
  }

  /// Check that one-pass cutoff does trigger.
  @Test func onePassCutoff() throws {
    let re = try Syntax.parse(#"^x{1,1000}y{1,1000}$"#, .perl)
    let p = Syntax.compile(re.simplify())
    #expect(compileOnePass(p) == nil, "makeOnePass succeeded; wanted nil")
  }

  /// Check that the same machine can be used with the standard matcher
  /// and then the backtracker when there are no captures.
  @Test func switchBacktrack() throws {
    let re = try Regexp.compile(#"a|b"#)
    let long = [UInt8](repeating: 0, count: maxBacktrackVector + 1)

    // The following sequence of Match calls used to panic. See issue #10319.
    _ = re.match(long)  // triggers standard matcher
    _ = re.match(Array(long[..<1]))  // triggers backtracker
  }

  @Test func minInputLen() throws {
    for tt in minInputLenTests {
      let re = try Syntax.parse(tt.regexp, .perl)
      let m = Regexp.minInputLen(re)
      #expect(m == tt.min, "regexp \(tt.regexp) has minInputLen \(m), should be \(tt.min)")
    }
  }
}
